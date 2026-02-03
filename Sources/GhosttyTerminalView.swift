import Foundation
import SwiftUI
import AppKit
import Metal
import QuartzCore
import Combine
import Darwin
import Sentry
import Network

struct CmuxdSessionInfo: Identifiable, Hashable {
    let id: String
    let paneId: String
    let title: String
    let cwd: String
}

struct CmuxdSessionRef: Hashable {
    let connectionId: String
    var sessionId: String?
    var paneId: String?
}

final class LineBuffer {
    private var buffer = Data()

    func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let range = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            if lineData.isEmpty { continue }
            if let line = String(data: lineData, encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .newlines)
                if !trimmed.isEmpty {
                    lines.append(trimmed)
                }
            }
        }
        return lines
    }

    func clear() {
        buffer.removeAll()
    }
}

protocol CmuxdTransport: AnyObject {
    var onMessage: ((String) -> Void)? { get set }
    var onClose: ((String) -> Void)? { get set }
    func connect()
    func send(_ text: String)
    func close()
}

final class CmuxdWebSocketTransport: CmuxdTransport {
    private let url: URL
    private let session: URLSession
    private let queue = DispatchQueue(label: "cmuxd.ws.transport")
    private var task: URLSessionWebSocketTask?

    var onMessage: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    init(url: URL) {
        self.url = url
        self.session = URLSession(configuration: .default)
    }

    func connect() {
        guard task == nil else { return }
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop()
    }

    func send(_ text: String) {
        queue.async { [weak self] in
            guard let self, let task = self.task else {
                self?.onClose?("Connection failed")
                return
            }
            task.send(.string(text)) { [weak self] error in
                if error != nil {
                    self?.onClose?("Connection failed")
                }
            }
        }
    }

    func close() {
        queue.async { [weak self] in
            self?.task?.cancel(with: .goingAway, reason: nil)
            self?.task = nil
        }
    }

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.onClose?("Connection failed")
                return
            case .success(let message):
                switch message {
                case .string(let text):
                    self.onMessage?(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.onMessage?(text)
                    }
                @unknown default:
                    break
                }
            }
            self.receiveLoop()
        }
    }
}

final class CmuxdUnixSocketTransport: CmuxdTransport {
    private let path: String
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private let buffer = LineBuffer()

    var onMessage: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    init(path: String, label: String) {
        self.path = path
        self.queue = DispatchQueue(label: "cmuxd.unix.\(label)")
    }

    var socketPath: String { path }

    func isSocketPresent() -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func connect() {
        guard connection == nil else { return }
        let conn = NWConnection(to: .unix(path: path), using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.onClose?("Connection failed: \(error)")
            }
            if case .cancelled = state {
                self.onClose?("Connection closed")
            }
        }
        conn.start(queue: queue)
        receiveLoop()
    }

    func send(_ text: String) {
        guard let connection else {
            onClose?("Connection failed")
            return
        }
        let payload = (text + "\n").data(using: .utf8) ?? Data()
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.onClose?("Connection failed")
            }
        })
    }

    func close() {
        connection?.cancel()
        connection = nil
        buffer.clear()
    }

    private func receiveLoop() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                for line in self.buffer.append(data) {
                    self.onMessage?(line)
                }
            }
            if error != nil || isComplete {
                self.onClose?("Connection closed")
                return
            }
            self.receiveLoop()
        }
    }
}

final class CmuxdStdioTransport: CmuxdTransport {
    private let command: [String]
    private let queue: DispatchQueue
    private let buffer = LineBuffer()
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?

    var onMessage: ((String) -> Void)?
    var onClose: ((String) -> Void)?

    init(command: [String], label: String) {
        self.command = command
        self.queue = DispatchQueue(label: "cmuxd.stdio.\(label)")
    }

    func connect() {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        if command.count > 1 {
            process.arguments = Array(command.dropFirst())
        }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.onClose?("Connection closed")
            }
        }

        do {
            try process.run()
        } catch {
            onClose?("Failed to launch connection: \(error.localizedDescription)")
            return
        }

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                self.onClose?("Connection closed")
                return
            }
            for line in self.buffer.append(data) {
                self.onMessage?(line)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
    }

    func send(_ text: String) {
        queue.async { [weak self] in
            guard let self, let pipe = self.stdinPipe else {
                self?.onClose?("Connection failed")
                return
            }
            let payload = (text + "\n").data(using: .utf8) ?? Data()
            pipe.fileHandleForWriting.write(payload)
        }
    }

    func close() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdinPipe?.fileHandleForWriting.closeFile()
        stdoutPipe?.fileHandleForReading.closeFile()
        process?.terminate()
        process = nil
        buffer.clear()
    }
}

final class CmuxdPane {
    let id: String
    let sessionId: String?
    let connectionId: String
    let connectionLabel: String
    private weak var connection: CmuxdConnection?
    var onOutput: ((Data) -> Void)?
    var onSnapshot: ((Data, Int, Int) -> Void)?
    var onExit: ((Int) -> Void)?
    var onTitle: ((String) -> Void)?
    var onCwd: ((String) -> Void)?
    var onNotify: ((String, String) -> Void)?

    init(id: String, sessionId: String?, connection: CmuxdConnection) {
        self.id = id
        self.sessionId = sessionId
        self.connection = connection
        self.connectionId = connection.id
        self.connectionLabel = connection.label
    }

    func sendInput(_ data: Data) {
        connection?.sendMessage([
            "type": "input",
            "pane_id": id,
            "data": data.base64EncodedString(),
        ])
    }

    func sendResize(cols: Int, rows: Int) {
        connection?.sendMessage([
            "type": "resize",
            "pane_id": id,
            "cols": cols,
            "rows": rows,
        ])
    }

    func requestSnapshot() {
        connection?.sendMessage([
            "type": "snapshot_request",
            "pane_id": id,
        ])
    }

    func close() {
        connection?.sendMessage([
            "type": "close_pane",
            "pane_id": id,
        ])
    }
}

final class CmuxdConnection {
    enum State: Equatable {
        case disconnected
        case connecting
        case ready
        case failed(String)
    }

    struct SessionRequestOptions {
        var cwd: String?
        var term: String?
        var cols: Int?
        var rows: Int?

        init(cwd: String? = nil, term: String? = nil, cols: Int? = nil, rows: Int? = nil) {
            self.cwd = cwd
            self.term = term
            self.cols = cols
            self.rows = rows
        }
    }

    private struct PendingSessionRequest {
        let options: SessionRequestOptions
        let completion: (CmuxdPane) -> Void
    }

    let id: String
    let label: String
    private let transport: CmuxdTransport
    private let queue: DispatchQueue
    private var isReady = false
    private var capabilities: Set<String> = []
    private var defaultSessionId: String?
    private var pendingSessionRequests: [PendingSessionRequest] = []
    private var sessionRequestInFlight = false
    private var pendingAttachRequests: [String: (CmuxdPane) -> Void] = [:]
    private var pendingAttachSent: Set<String> = []
    private var paneHandlers: [String: CmuxdPane] = [:]
    private var pendingSessionListHandlers: [([CmuxdSessionInfo]) -> Void] = []
    private var pendingSessionListRequest = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var helloTimeoutWorkItem: DispatchWorkItem?
    private var reconnectAttempts = 0
    private var connectStart: Date?
    private var awaitingSocket = false
    private var socketWaitStart: Date?
    private var state: State = .disconnected {
        didSet {
            if state != oldValue {
                DispatchQueue.main.async { [state] in
                    self.onStateChange?(state)
                }
            }
        }
    }

    var onStateChange: ((State) -> Void)?
    var onHandshakeTimeout: (() -> Void)?

    init(id: String, label: String, transport: CmuxdTransport) {
        self.id = id
        self.label = label
        self.transport = transport
        self.queue = DispatchQueue(label: "cmuxd.connection.\(id)")
        transport.onMessage = { [weak self] text in
            self?.queue.async {
                self?.handleMessage(text)
            }
        }
        transport.onClose = { [weak self] message in
            self?.resetConnection(error: message)
        }
    }

    func stateSnapshot() -> State {
        queue.sync { state }
    }

    func connectIfNeeded() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isReady else { return }
            if self.state == .connecting, !self.awaitingSocket {
                return
            }
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.state = .connecting
            if self.connectStart == nil {
                self.connectStart = Date()
                CmuxdManager.logTiming("connect start conn=\(self.label) transport=\(self.transportDescription())")
            }
            if let unix = self.transport as? CmuxdUnixSocketTransport, !unix.isSocketPresent() {
                if self.socketWaitStart == nil {
                    self.socketWaitStart = Date()
                    CmuxdManager.logTiming("waiting for unix socket conn=\(self.label) path=\(unix.socketPath)")
                }
                self.awaitingSocket = true
                self.scheduleReconnect(delayOverride: 0.05, incrementAttempts: false)
                return
            }
            if let unix = self.transport as? CmuxdUnixSocketTransport, let waitStart = self.socketWaitStart {
                let elapsed = Date().timeIntervalSince(waitStart)
                CmuxdManager.logTiming(String(format: "unix socket ready conn=%@ after %.3fs path=%@",
                                              self.label, elapsed, unix.socketPath))
            }
            self.socketWaitStart = nil
            self.awaitingSocket = false
            self.transport.connect()
            self.startHandshake()
        }
    }

    func requestSession(options: SessionRequestOptions = SessionRequestOptions(), completion: @escaping (CmuxdPane) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.connectIfNeeded()
            self.pendingSessionRequests.append(.init(options: options, completion: completion))
            self.flushSessionRequests()
        }
    }

    func attachSession(id sessionId: String, completion: @escaping (CmuxdPane) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.connectIfNeeded()
            self.pendingAttachRequests[sessionId] = completion
            self.flushAttachRequests()
        }
    }

    func fetchSessionList(completion: @escaping ([CmuxdSessionInfo]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.connectIfNeeded()
            self.pendingSessionListHandlers.append(completion)
            self.pendingSessionListRequest = true
            self.flushSessionListRequests()
        }
    }

    func sendMessage(_ payload: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.connectIfNeeded()
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let text = String(data: data, encoding: .utf8) {
                self.transport.send(text)
            }
        }
    }

    private var supportsSessions: Bool {
        capabilities.contains("sessions")
    }

    private func sendHello() {
        sendMessage(["type": "hello", "version": 1])
    }

    private func startHandshake() {
        sendHello()
        scheduleHelloTimeout()
    }

    private func scheduleHelloTimeout() {
        helloTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isReady {
                let start = self.connectStart ?? Date()
                let elapsed = Date().timeIntervalSince(start)
                if elapsed < 10.0 {
                    self.sendHello()
                    self.scheduleHelloTimeout()
                    return
                }
                self.onHandshakeTimeout?()
                self.resetConnection(error: "Handshake timeout")
            }
        }
        helloTimeoutWorkItem = item
        queue.asyncAfter(deadline: .now() + 3.0, execute: item)
    }

    private func clearHelloTimeout() {
        helloTimeoutWorkItem?.cancel()
        helloTimeoutWorkItem = nil
    }

    private func flushSessionRequests() {
        guard isReady else { return }
        guard !sessionRequestInFlight else { return }
        guard !pendingSessionRequests.isEmpty else { return }
        sessionRequestInFlight = true
        let request = pendingSessionRequests[0]
        var payload: [String: Any] = ["type": supportsSessions ? "new_session" : "new_pane"]
        if let cwd = request.options.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cwd.isEmpty {
            payload["cwd"] = cwd
        }
        if let term = request.options.term?.trimmingCharacters(in: .whitespacesAndNewlines),
           !term.isEmpty {
            payload["term"] = term
        }
        if let cols = request.options.cols, cols > 0 {
            payload["cols"] = cols
        }
        if let rows = request.options.rows, rows > 0 {
            payload["rows"] = rows
        }
        sendMessage(payload)
    }

    private func flushSessionListRequests() {
        guard isReady else { return }
        guard pendingSessionListRequest else { return }
        pendingSessionListRequest = false
        if supportsSessions {
            sendMessage(["type": "list_sessions"])
        } else {
            sendMessage(["type": "list_panes"])
        }
    }

    private func flushAttachRequests() {
        guard isReady else { return }
        if supportsSessions {
            for sessionId in pendingAttachRequests.keys {
                guard !pendingAttachSent.contains(sessionId) else { continue }
                pendingAttachSent.insert(sessionId)
                sendMessage(["type": "attach_session", "session_id": sessionId])
            }
        } else {
            let requests = pendingAttachRequests
            pendingAttachRequests.removeAll()
            pendingAttachSent.removeAll()
            for (sessionId, completion) in requests {
                attachPane(id: sessionId, completion: completion)
            }
        }
    }

    private func drainSessionListHandlers(with list: [CmuxdSessionInfo]) {
        guard !pendingSessionListHandlers.isEmpty else { return }
        let handlers = pendingSessionListHandlers
        pendingSessionListHandlers.removeAll()
        DispatchQueue.main.async {
            handlers.forEach { $0(list) }
        }
    }

    private func attachPane(id: String, completion: @escaping (CmuxdPane) -> Void) {
        let pane = CmuxdPane(id: id, sessionId: id, connection: self)
        paneHandlers[id] = pane
        DispatchQueue.main.async {
            completion(pane)
        }
    }

    private func resetConnection(error: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.transport.close()
            self.isReady = false
            self.sessionRequestInFlight = false
            self.pendingAttachSent.removeAll()
            self.clearHelloTimeout()
            self.connectStart = nil
            self.awaitingSocket = false
            self.socketWaitStart = nil
            let message = error ?? "Disconnected"
            self.state = .failed(message)
            if !self.pendingSessionRequests.isEmpty || !self.pendingSessionListHandlers.isEmpty || !self.paneHandlers.isEmpty {
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect(delayOverride: TimeInterval? = nil, incrementAttempts: Bool = true) {
        guard reconnectWorkItem == nil else { return }
        let delay: TimeInterval
        if let delayOverride {
            delay = delayOverride
        } else {
            let attempt = reconnectAttempts
            delay = min(0.2 * pow(2.0, Double(attempt)), 3.0)
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnectWorkItem = nil
            if incrementAttempts {
                self.reconnectAttempts += 1
            }
            self.connectIfNeeded()
        }
        reconnectWorkItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        guard let value = try? JSONSerialization.jsonObject(with: data) else { return }
        guard let obj = value as? [String: Any] else { return }
        guard let type = obj["type"] as? String else { return }

        switch type {
        case "welcome":
            isReady = true
            reconnectAttempts = 0
            clearHelloTimeout()
            if let start = connectStart {
                let elapsed = Date().timeIntervalSince(start)
                CmuxdManager.logTiming(String(format: "handshake ready conn=%@ after %.3fs", self.label, elapsed))
            }
            connectStart = nil
            awaitingSocket = false
            socketWaitStart = nil
            if let caps = obj["capabilities"] as? [String] {
                capabilities = Set(caps)
            }
            defaultSessionId = obj["session_id"] as? String
            state = .ready
            flushSessionRequests()
            flushSessionListRequests()
            flushAttachRequests()
        case "capabilities":
            if let caps = obj["capabilities"] as? [String] {
                capabilities = Set(caps)
            }
            flushAttachRequests()
        case "session_created", "pane_created":
            guard let paneId = obj["pane_id"] as? String else { return }
            let sessionId = (obj["session_id"] as? String) ?? defaultSessionId ?? paneId
            let pane = CmuxdPane(id: paneId, sessionId: sessionId, connection: self)
            paneHandlers[paneId] = pane
            if !pendingSessionRequests.isEmpty {
                let request = pendingSessionRequests.removeFirst()
                sessionRequestInFlight = false
                DispatchQueue.main.async {
                    request.completion(pane)
                }
                flushSessionRequests()
            }
        case "session_attached":
            guard let sessionId = obj["session_id"] as? String else { return }
            guard let paneId = obj["pane_id"] as? String else { return }
            let pane = CmuxdPane(id: paneId, sessionId: sessionId, connection: self)
            paneHandlers[paneId] = pane
            pendingAttachSent.remove(sessionId)
            if let completion = pendingAttachRequests.removeValue(forKey: sessionId) {
                DispatchQueue.main.async {
                    completion(pane)
                }
            }
        case "sessions":
            let sessions = (obj["sessions"] as? [[String: Any]] ?? []).compactMap { item -> CmuxdSessionInfo? in
                guard let sessionId = item["session_id"] as? String else { return nil }
                let paneId = item["pane_id"] as? String ?? sessionId
                let title = item["title"] as? String ?? ""
                let cwd = item["cwd"] as? String ?? ""
                return CmuxdSessionInfo(id: sessionId, paneId: paneId, title: title, cwd: cwd)
            }
            drainSessionListHandlers(with: sessions)
        case "panes":
            let panes = (obj["panes"] as? [[String: Any]] ?? []).compactMap { item -> CmuxdSessionInfo? in
                guard let paneId = item["pane_id"] as? String else { return nil }
                let sessionId = (item["session_id"] as? String) ?? paneId
                return CmuxdSessionInfo(id: sessionId, paneId: paneId, title: "", cwd: "")
            }
            drainSessionListHandlers(with: panes)
        case "output":
            guard let paneId = obj["pane_id"] as? String else { return }
            guard let b64 = obj["data"] as? String else { return }
            guard let data = Data(base64Encoded: b64) else { return }
            if let pane = paneHandlers[paneId] {
                pane.onOutput?(data)
            }
        case "snapshot":
            guard let paneId = obj["pane_id"] as? String else { return }
            guard let b64 = obj["data"] as? String else { return }
            guard let data = Data(base64Encoded: b64) else { return }
            let cols = obj["cols"] as? Int ?? 0
            let rows = obj["rows"] as? Int ?? 0
            if let pane = paneHandlers[paneId] {
                pane.onSnapshot?(data, cols, rows)
            }
        case "title_update":
            guard let paneId = obj["pane_id"] as? String else { return }
            let title = obj["title"] as? String ?? ""
            if let pane = paneHandlers[paneId] {
                DispatchQueue.main.async {
                    pane.onTitle?(title)
                }
            }
        case "cwd_update":
            guard let paneId = obj["pane_id"] as? String else { return }
            let cwd = obj["cwd"] as? String ?? ""
            if let pane = paneHandlers[paneId] {
                DispatchQueue.main.async {
                    pane.onCwd?(cwd)
                }
            }
        case "notify":
            guard let paneId = obj["pane_id"] as? String else { return }
            let title = obj["title"] as? String ?? ""
            let body = obj["body"] as? String ?? ""
            if let pane = paneHandlers[paneId] {
                DispatchQueue.main.async {
                    pane.onNotify?(title, body)
                }
            }
        case "pane_exited":
            guard let paneId = obj["pane_id"] as? String else { return }
            let exitCode = obj["exit_code"] as? Int ?? 0
            if let pane = paneHandlers.removeValue(forKey: paneId) {
                DispatchQueue.main.async {
                    pane.onExit?(exitCode)
                }
            }
        case "error":
            if let message = obj["message"] as? String {
                state = .failed(message)
            }
        default:
            break
        }
    }

    private func transportDescription() -> String {
        if let unix = transport as? CmuxdUnixSocketTransport {
            return "unix:\(unix.socketPath)"
        }
        if transport is CmuxdWebSocketTransport {
            return "ws"
        }
        if transport is CmuxdStdioTransport {
            return "stdio"
        }
        return "unknown"
    }
}

final class CmuxdManager {
    static let shared = CmuxdManager()
    static let timingsEnabled: Bool = {
        let env = (ProcessInfo.processInfo.environment["CMUXD_TIMINGS"] ?? "").lowercased()
        return env == "1" || env == "true" || env == "yes"
    }()
    private static let timingsQueue = DispatchQueue(label: "cmuxd.timing.log")

    static func logTiming(_ message: String) {
        guard timingsEnabled else { return }
        NSLog("[cmuxd.timing] %@", message)
        timingsQueue.async {
            guard let url = timingLogURL() else { return }
            let timestamp = String(format: "%.3f", Date().timeIntervalSince1970)
            let line = "[\(timestamp)] \(message)\n"
            let data = Data(line.utf8)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    private let port: UInt16
    private let host = "127.0.0.1"
    private let stateQueue = DispatchQueue(label: "cmuxd.manager")
    private let localConnectionId = "local"
    private let unixSocketPath: String?

    private(set) var connections: [CmuxdConnection] = []
    private var connectionsById: [String: CmuxdConnection] = [:]
    var connection: CmuxdConnection? { connectionsById[localConnectionId] }
    var defaultConnectionId: String? { connections.first?.id }
    let isEnabled: Bool
    private let cmuxdPath: String?
    private var launchProcess: Process?
    private var logHandle: FileHandle?
    private var logPath: String?
    private var lastErrorMessage: String?
    private var lastRestartAttempt: Date?

    private struct ConnectionsConfig: Codable {
        let connections: [ConnectionConfig]
    }

    private struct ConnectionConfig: Codable {
        let id: String
        let name: String
        let type: String
        let url: String?
        let path: String?
        let host: String?
        let command: String?
        let args: [String]?
    }

    private init() {
        self.port = Self.resolvePort()
        if ProcessInfo.processInfo.environment["CMUXD_DISABLE"] == "1" {
            self.isEnabled = false
            self.cmuxdPath = nil
            self.unixSocketPath = nil
            return
        }
        let resolvedPath = Self.resolveCmuxdPathStatic()
        self.cmuxdPath = resolvedPath
        self.unixSocketPath = Self.resolveUnixSocketPath()
        let remoteConnections = Self.loadRemoteConnections()
        var builtConnections: [CmuxdConnection] = []

        if resolvedPath != nil {
            let transport: CmuxdTransport
            if let unixSocketPath {
                transport = CmuxdUnixSocketTransport(path: unixSocketPath, label: localConnectionId)
            } else {
                transport = CmuxdWebSocketTransport(url: URL(string: "ws://\(host):\(port)")!)
            }
            let local = CmuxdConnection(id: localConnectionId, label: "Local", transport: transport)
            builtConnections.append(local)
        }

        builtConnections.append(contentsOf: remoteConnections)
        self.connections = builtConnections
        self.connectionsById = Dictionary(uniqueKeysWithValues: builtConnections.map { ($0.id, $0) })
        self.isEnabled = !builtConnections.isEmpty
        self.logPath = Self.defaultLogPath()
        if let local = self.connectionsById[localConnectionId] {
            local.onHandshakeTimeout = { [weak self] in
                self?.handleLocalHandshakeTimeout()
            }
        }
        if resolvedPath != nil {
            startIfNeeded()
        }
        connection?.connectIfNeeded()
    }

    func startIfNeeded() {
        guard cmuxdPath != nil else { return }
        stateQueue.async {
            if self.isLocalReady() {
                return
            }
            guard let binPath = self.cmuxdPath else {
                NSLog("cmuxd: binary not found; falling back to local PTY")
                self.lastErrorMessage = "cmuxd binary not found"
                return
            }
            self.launchCmuxd(binPath: binPath)
        }
    }

    func isLocalReadySnapshot() -> Bool {
        stateQueue.sync { isLocalReady() }
    }

    func connection(for id: String?) -> CmuxdConnection? {
        if let id {
            return connectionsById[id]
        }
        return connection
    }

    func fetchSessionList(connectionId: String? = nil, completion: @escaping ([CmuxdSessionInfo]) -> Void) {
        connection(for: connectionId)?.fetchSessionList(completion: completion)
    }

    func requestSession(
        connectionId: String? = nil,
        options: CmuxdConnection.SessionRequestOptions = .init(),
        completion: @escaping (CmuxdPane) -> Void
    ) {
        connection(for: connectionId)?.requestSession(options: options, completion: completion)
    }

    private static func resolveCmuxdPathStatic() -> String? {
        if let env = ProcessInfo.processInfo.environment["CMUXD_BIN"], !env.isEmpty {
            return env
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let supportBin = appSupport?.appendingPathComponent("cmuxterm/bin/cmuxd")
        if let resourceBin = Bundle.main.resourceURL?.appendingPathComponent("bin/cmuxd"),
           FileManager.default.isExecutableFile(atPath: resourceBin.path) {
            if let supportDir = supportBin?.deletingLastPathComponent() {
                try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
                if let supportBin, FileManager.default.fileExists(atPath: supportBin.path) {
                    try? FileManager.default.removeItem(at: supportBin)
                }
                try? FileManager.default.copyItem(at: resourceBin, to: supportBin!)
                return supportBin?.path ?? resourceBin.path
            }
            return resourceBin.path
        }
        if let supportBin, FileManager.default.isExecutableFile(atPath: supportBin.path) {
            return supportBin.path
        }
        return nil
    }

    private static func resolveUnixSocketPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["CMUXD_UNIX_PATH"] {
            let trimmed = env.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return nil
            }
            return NSString(string: trimmed).expandingTildeInPath
        }
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let isDev = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)?
            .localizedCaseInsensitiveContains("DEV") == true
        let socketName = isDev ? "cmuxd-dev.sock" : "cmuxd.sock"
        return appSupport
            .appendingPathComponent("cmuxterm")
            .appendingPathComponent(socketName)
            .path
    }

    private static func connectionsConfigURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cmuxterm/remote-connections.json")
    }

    private static func loadRemoteConnections() -> [CmuxdConnection] {
        guard let url = connectionsConfigURL(),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        guard let config = try? decoder.decode(ConnectionsConfig.self, from: data) else {
            return []
        }
        var results: [CmuxdConnection] = []
        for entry in config.connections {
            guard !entry.id.isEmpty else { continue }
            let label = entry.name.isEmpty ? entry.id : entry.name
            switch entry.type.lowercased() {
            case "ws":
                guard let urlString = entry.url, let url = URL(string: urlString) else { continue }
                let transport = CmuxdWebSocketTransport(url: url)
                results.append(CmuxdConnection(id: entry.id, label: label, transport: transport))
            case "unix":
                guard let path = entry.path else { continue }
                let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedPath.isEmpty else { continue }
                let resolvedPath = NSString(string: trimmedPath).expandingTildeInPath
                let transport = CmuxdUnixSocketTransport(path: resolvedPath, label: entry.id)
                results.append(CmuxdConnection(id: entry.id, label: label, transport: transport))
            case "ssh", "stdio":
                guard let host = entry.host, !host.isEmpty else { continue }
                var command: [String] = ["/usr/bin/ssh", "-T", host]
                if let args = entry.args {
                    command.append(contentsOf: args)
                }
                command.append(entry.command ?? "cmuxd --stdio")
                let transport = CmuxdStdioTransport(command: command, label: entry.id)
                results.append(CmuxdConnection(id: entry.id, label: label, transport: transport))
            default:
                continue
            }
        }
        return results
    }

    private func launchCmuxd(binPath: String) {
        if let launchProcess, launchProcess.isRunning {
            return
        }
        let unixPath = unixSocketPath ?? ""
        let mode = unixPath.isEmpty ? "ws" : "unix"
        Self.logTiming("launching cmuxd mode=\(mode) bin=\(binPath) unix=\(unixPath)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binPath)
        var arguments: [String] = []
        if let unixSocketPath {
            let socketDir = URL(fileURLWithPath: unixSocketPath).deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)
            arguments.append(contentsOf: ["--unix", unixSocketPath])
        } else {
            arguments.append(contentsOf: ["--ws", "\(host):\(port)"])
        }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if environment["CMUXD_DEFAULT_CWD"] == nil {
            let config = GhosttyConfig.load()
            let trimmed = config.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                environment["CMUXD_DEFAULT_CWD"] = NSString(string: trimmed).expandingTildeInPath
            } else {
                environment["CMUXD_DEFAULT_CWD"] = FileManager.default.homeDirectoryForCurrentUser.path
            }
        }
        if environment["COLORTERM"] == nil {
            environment["COLORTERM"] = "truecolor"
        }
        if environment["TERM_PROGRAM"] == nil {
            environment["TERM_PROGRAM"] = "ghostty"
        }
        if environment["TERM_PROGRAM_VERSION"] == nil {
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               !version.isEmpty {
                environment["TERM_PROGRAM_VERSION"] = version
            }
        }
        if environment["TERMINFO"] == nil {
            let fileManager = FileManager.default
            let resourceURL = Bundle.main.resourceURL
            let candidates = [
                resourceURL?.appendingPathComponent("ghostty/terminfo"),
                resourceURL?.appendingPathComponent("terminfo"),
            ]
            for candidate in candidates {
                if let candidate, fileManager.fileExists(atPath: candidate.path) {
                    environment["TERMINFO"] = candidate.path
                    break
                }
            }
        }
        if environment["GHOSTTY_RESOURCES_DIR"] == nil {
            let fileManager = FileManager.default
            let resourceURL = Bundle.main.resourceURL
            let candidates = [
                resourceURL?.appendingPathComponent("ghostty"),
                resourceURL,
            ]
            for candidate in candidates {
                guard let candidate else { continue }
                let integrationDir = candidate.appendingPathComponent("shell-integration")
                if fileManager.fileExists(atPath: integrationDir.path) {
                    environment["GHOSTTY_RESOURCES_DIR"] = candidate.path
                    break
                }
            }
        }
        process.environment = environment
        if let logURL = prepareLogFile() {
            logPath = logURL.path
            if let handle = try? FileHandle(forWritingTo: logURL) {
                logHandle = handle
                try? handle.truncate(atOffset: 0)
                process.standardOutput = handle
                process.standardError = handle
            } else {
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        lastErrorMessage = nil
        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.stateQueue.async {
                let code = proc.terminationStatus
                let reason = proc.terminationReason
                self.lastErrorMessage = "cmuxd exited (status \(code), reason \(reason))"
            }
        }
        do {
            try process.run()
            launchProcess = process
            Self.logTiming("cmuxd started pid=\(process.processIdentifier)")
        } catch {
            NSLog("cmuxd: failed to launch: \(error)")
            lastErrorMessage = "Failed to launch cmuxd: \(error.localizedDescription)"
        }
    }

    private func handleLocalHandshakeTimeout() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard self.cmuxdPath != nil else { return }
            let now = Date()
            if let lastRestartAttempt, now.timeIntervalSince(lastRestartAttempt) < 5.0 {
                return
            }
            lastRestartAttempt = now
            Self.logTiming("handshake timeout: restarting local cmuxd")
            if let unixSocketPath {
                try? FileManager.default.removeItem(atPath: unixSocketPath)
            }
            if let launchProcess, launchProcess.isRunning {
                launchProcess.terminate()
            }
            launchProcess = nil
            self.launchCmuxd(binPath: self.cmuxdPath!)
        }
    }

    private func prepareLogFile() -> URL? {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let logDir = appSupport.appendingPathComponent("cmuxterm")
        do {
            try fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return logDir.appendingPathComponent("cmuxd.log")
    }

    private static func defaultLogPath() -> String? {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent("cmuxterm")
            .appendingPathComponent("cmuxd.log")
            .path
    }

    private static func timingLogURL() -> URL? {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let logDir = appSupport.appendingPathComponent("cmuxterm")
        try? fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
        return logDir.appendingPathComponent("cmuxd-timing.log")
    }

    func describeFailure() -> String? {
        stateQueue.sync {
            var parts: [String] = []
            if let lastErrorMessage, !lastErrorMessage.isEmpty {
                parts.append(lastErrorMessage)
            }
            let resolvedLogPath = logPath ?? Self.defaultLogPath()
            if let resolvedLogPath, !resolvedLogPath.isEmpty {
                parts.append("log: \(resolvedLogPath)")
            }
            if let unixSocketPath {
                let exists = FileManager.default.fileExists(atPath: unixSocketPath)
                parts.append("unix socket: \(exists ? "present" : "missing")")
            } else {
                let portStatus = isPortOpen() ? "port \(port) open" : "port \(port) closed"
            parts.append(portStatus)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    private func isLocalReady() -> Bool {
        if let unixSocketPath {
            return isUnixSocketActive(path: unixSocketPath)
        }
        return isPortOpen()
    }

    private func isPortOpen() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let host = NWEndpoint.Host(self.host)
        guard let port = NWEndpoint.Port(rawValue: port) else { return false }
        let queue = DispatchQueue(label: "cmuxd.portcheck")
        let conn = NWConnection(host: host, port: port, using: .tcp)
        var isOpen = false
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                isOpen = true
                conn.cancel()
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        conn.start(queue: queue)
        if semaphore.wait(timeout: .now() + 0.3) == .timedOut {
            conn.cancel()
        }
        return isOpen
    }

    private func isUnixSocketActive(path: String) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= maxLen else { return false }

        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            let rawPtr = UnsafeMutableRawPointer(sunPathPtr).assumingMemoryBound(to: Int8.self)
            memset(rawPtr, 0, maxLen)
            _ = pathBytes.withUnsafeBufferPointer { buffer in
                strncpy(rawPtr, buffer.baseAddress, maxLen - 1)
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }

        var isActive = false
        let addrLen = socklen_t(MemoryLayout.size(ofValue: addr))
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                connect(fd, saPtr, addrLen)
            }
        }
        if result == 0 {
            isActive = true
        } else {
            if errno == ECONNREFUSED {
                try? FileManager.default.removeItem(atPath: path)
            }
            isActive = false
        }
        return isActive
    }

    private static func resolvePort() -> UInt16 {
        if let env = ProcessInfo.processInfo.environment["CMUXD_PORT"],
           let value = UInt16(env) {
            return value
        }
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           name.localizedCaseInsensitiveContains("DEV") {
            return 4071
        }
        return 4070
    }
}

private enum GhosttyPasteboardHelper {
    private static let selectionPasteboard = NSPasteboard(
        name: NSPasteboard.Name("com.mitchellh.ghostty.selection")
    )
    private static let utf8PlainTextType = NSPasteboard.PasteboardType("public.utf8-plain-text")
    private static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return .general
        case GHOSTTY_CLIPBOARD_SELECTION:
            return selectionPasteboard
        default:
            return nil
        }
    }

    static func stringContents(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            return urls
                .map { $0.isFileURL ? escapeForShell($0.path) : $0.absoluteString }
                .joined(separator: " ")
        }

        if let value = pasteboard.string(forType: .string) {
            return value
        }

        return pasteboard.string(forType: utf8PlainTextType)
    }

    static func hasString(for location: ghostty_clipboard_e) -> Bool {
        guard let pasteboard = pasteboard(for: location) else { return false }
        return (stringContents(from: pasteboard) ?? "").isEmpty == false
    }

    static func writeString(_ string: String, to location: ghostty_clipboard_e) {
        guard let pasteboard = pasteboard(for: location) else { return }
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private static func escapeForShell(_ value: String) -> String {
        var result = value
        for char in shellEscapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }
}

// Minimal Ghostty wrapper for terminal rendering
// This uses libghostty (GhosttyKit.xcframework) for actual terminal emulation

// MARK: - Ghostty App Singleton

class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var defaultBackgroundColor: NSColor = .windowBackgroundColor
    private(set) var defaultBackgroundOpacity: Double = 1.0
    let backgroundLogEnabled = {
        if ProcessInfo.processInfo.environment["CMUX_DEBUG_BG"] == "1" {
            return true
        }
        if ProcessInfo.processInfo.environment["GHOSTTYTABS_DEBUG_BG"] == "1" {
            return true
        }
        if UserDefaults.standard.bool(forKey: "cmuxDebugBG") {
            return true
        }
        return UserDefaults.standard.bool(forKey: "GhosttyTabsDebugBG")
    }()
    private let backgroundLogURL = URL(fileURLWithPath: "/tmp/cmux-bg.log")
    private var appObservers: [NSObjectProtocol] = []

    // Scroll lag tracking
    private(set) var isScrolling = false
    private var scrollLagSampleCount = 0
    private var scrollLagTotalMs: Double = 0
    private var scrollLagMaxMs: Double = 0
    private let scrollLagThresholdMs: Double = 25  // Alert if tick takes >25ms during scroll
    private var scrollEndTimer: DispatchWorkItem?

    func markScrollActivity(hasMomentum: Bool, momentumEnded: Bool) {
        // Cancel any pending scroll-end timer
        scrollEndTimer?.cancel()
        scrollEndTimer = nil

        if momentumEnded {
            // Trackpad momentum ended - scrolling is done
            endScrollSession()
        } else if hasMomentum {
            // Trackpad scrolling with momentum - wait for momentum to end
            isScrolling = true
        } else {
            // Mouse wheel or non-momentum scroll - use timeout
            isScrolling = true
            let timer = DispatchWorkItem { [weak self] in
                self?.endScrollSession()
            }
            scrollEndTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: timer)
        }
    }

    private func endScrollSession() {
        guard isScrolling else { return }
        isScrolling = false

        // Report accumulated lag stats if any exceeded threshold
        if scrollLagSampleCount > 0 {
            let avgLag = scrollLagTotalMs / Double(scrollLagSampleCount)
            let maxLag = scrollLagMaxMs
            let samples = scrollLagSampleCount
            let threshold = scrollLagThresholdMs
            if maxLag > threshold {
                SentrySDK.capture(message: "Scroll lag detected") { scope in
                    scope.setLevel(.warning)
                    scope.setContext(value: [
                        "samples": samples,
                        "avg_ms": String(format: "%.2f", avgLag),
                        "max_ms": String(format: "%.2f", maxLag),
                        "threshold_ms": threshold
                    ], key: "scroll_lag")
                }
            }
            // Reset stats
            scrollLagSampleCount = 0
            scrollLagTotalMs = 0
            scrollLagMaxMs = 0
        }
    }

    private init() {
        initializeGhostty()
    }

    private func initializeGhostty() {
        // Ensure TUI apps can use colors even if NO_COLOR is set in the launcher env.
        if getenv("NO_COLOR") != nil {
            unsetenv("NO_COLOR")
        }

        // Initialize Ghostty library first
        let result = ghostty_init(0, nil)
        if result != GHOSTTY_SUCCESS {
            print("Failed to initialize ghostty: \(result)")
            return
        }

        // Load config
        config = ghostty_config_new()
        guard let config = config else {
            print("Failed to create ghostty config")
            return
        }

        // Load default config
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)
        updateDefaultBackground(from: config)

        // Create runtime config with callbacks
        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { userdata in
            DispatchQueue.main.async {
                GhosttyApp.shared.tick()
            }
        }
        runtimeConfig.action_cb = { app, target, action in
            return GhosttyApp.shared.handleAction(target: target, action: action)
        }
        runtimeConfig.read_clipboard_cb = { userdata, location, state in
            // Read clipboard
            guard let userdata else { return }
            let surfaceView = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.terminalSurface?.surface else { return }

            let pasteboard = GhosttyPasteboardHelper.pasteboard(for: location)
            let value = pasteboard.flatMap { GhosttyPasteboardHelper.stringContents(from: $0) } ?? ""

            value.withCString { ptr in
                ghostty_surface_complete_clipboard_request(surface, ptr, state, false)
            }
        }
        runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let userdata, let content else { return }
            let surfaceView = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()
            guard let surface = surfaceView.terminalSurface?.surface else { return }

            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }
        runtimeConfig.write_clipboard_cb = { _, location, content, len, _ in
            // Write clipboard
            guard let content = content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))

            var fallback: String?
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)

                if let mimePtr = item.mime {
                    let mime = String(cString: mimePtr)
                    if mime.hasPrefix("text/plain") {
                        GhosttyPasteboardHelper.writeString(value, to: location)
                        return
                    }
                }

                if fallback == nil {
                    fallback = value
                }
            }

            if let fallback {
                GhosttyPasteboardHelper.writeString(fallback, to: location)
            }
        }
        runtimeConfig.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            let surfaceView = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id else {
                return
            }

            DispatchQueue.main.async {
                if let surface = surfaceView.terminalSurface,
                   surface.needsConfirmClose() {
                    AppDelegate.shared?.tabManager?.closePanelWithConfirmation(
                        tabId: tabId,
                        surfaceId: surfaceId
                    )
                    return
                }
                _ = AppDelegate.shared?.tabManager?.closeSurface(tabId: tabId, surfaceId: surfaceId)
            }
        }

        // Create app
        app = ghostty_app_new(&runtimeConfig, config)
        if app == nil {
            print("Failed to create ghostty app")
            return
        }

        #if os(macOS)
        if let app {
            ghostty_app_set_focus(app, NSApp.isActive)
        }

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        })

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        })
        #endif
    }

    func tick() {
        guard let app = app else { return }

        let start = CACurrentMediaTime()
        ghostty_app_tick(app)
        let elapsedMs = (CACurrentMediaTime() - start) * 1000

        // Track lag during scrolling
        if isScrolling {
            scrollLagSampleCount += 1
            scrollLagTotalMs += elapsedMs
            scrollLagMaxMs = max(scrollLagMaxMs, elapsedMs)
        }
    }

    private func updateDefaultBackground(from config: ghostty_config_t?) {
        guard let config else { return }

        var color = ghostty_config_color_s()
        let bgKey = "background"
        if ghostty_config_get(config, &color, bgKey, UInt(bgKey.lengthOfBytes(using: .utf8))) {
            defaultBackgroundColor = NSColor(
                red: CGFloat(color.r) / 255,
                green: CGFloat(color.g) / 255,
                blue: CGFloat(color.b) / 255,
                alpha: 1.0
            )
        }

        var opacity: Double = 1.0
        let opacityKey = "background-opacity"
        _ = ghostty_config_get(config, &opacity, opacityKey, UInt(opacityKey.lengthOfBytes(using: .utf8)))
        defaultBackgroundOpacity = opacity
        if backgroundLogEnabled {
            logBackground("default background updated color=\(defaultBackgroundColor) opacity=\(String(format: "%.3f", defaultBackgroundOpacity))")
        }
    }

    private func performOnMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    private func splitDirection(from direction: ghostty_action_split_direction_e) -> SplitTree<TerminalSurface>.NewDirection? {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: return .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: return .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: return .down
        case GHOSTTY_SPLIT_DIRECTION_UP: return .up
        default: return nil
        }
    }

    private func focusDirection(from direction: ghostty_action_goto_split_e) -> SplitTree<TerminalSurface>.FocusDirection? {
        switch direction {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: return .previous
        case GHOSTTY_GOTO_SPLIT_NEXT: return .next
        case GHOSTTY_GOTO_SPLIT_UP: return .spatial(.up)
        case GHOSTTY_GOTO_SPLIT_DOWN: return .spatial(.down)
        case GHOSTTY_GOTO_SPLIT_LEFT: return .spatial(.left)
        case GHOSTTY_GOTO_SPLIT_RIGHT: return .spatial(.right)
        default: return nil
        }
    }

    private func resizeDirection(from direction: ghostty_action_resize_split_direction_e) -> SplitTree<TerminalSurface>.Spatial.Direction? {
        switch direction {
        case GHOSTTY_RESIZE_SPLIT_UP: return .up
        case GHOSTTY_RESIZE_SPLIT_DOWN: return .down
        case GHOSTTY_RESIZE_SPLIT_LEFT: return .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT: return .right
        default: return nil
        }
    }

    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        if target.tag != GHOSTTY_TARGET_SURFACE {
            if action.tag == GHOSTTY_ACTION_DESKTOP_NOTIFICATION,
               let tabManager = AppDelegate.shared?.tabManager,
               let tabId = tabManager.selectedTabId {
                let actionTitle = action.action.desktop_notification.title
                    .flatMap { String(cString: $0) } ?? ""
                let actionBody = action.action.desktop_notification.body
                    .flatMap { String(cString: $0) } ?? ""
                let tabTitle = AppDelegate.shared?.tabManager?.titleForTab(tabId) ?? "Terminal"
                let command = actionTitle.isEmpty ? tabTitle : actionTitle
                let body = actionBody
                let surfaceId = tabManager.focusedSurfaceId(for: tabId)
                DispatchQueue.main.async {
                    tabManager.moveTabToTop(tabId)
                    TerminalNotificationStore.shared.addNotification(
                        tabId: tabId,
                        surfaceId: surfaceId,
                        title: command,
                        subtitle: "",
                        body: body
                    )
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_COLOR_CHANGE,
               action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                let change = action.action.color_change
                defaultBackgroundColor = NSColor(
                    red: CGFloat(change.r) / 255,
                    green: CGFloat(change.g) / 255,
                    blue: CGFloat(change.b) / 255,
                    alpha: 1.0
                )
                if backgroundLogEnabled {
                    logBackground("OSC background change (app target) color=\(defaultBackgroundColor)")
                }
                DispatchQueue.main.async {
                    GhosttyApp.shared.applyBackgroundToKeyWindow()
                }
                return true
            }

            if action.tag == GHOSTTY_ACTION_CONFIG_CHANGE {
                updateDefaultBackground(from: action.action.config_change.config)
                DispatchQueue.main.async {
                    GhosttyApp.shared.applyBackgroundToKeyWindow()
                }
                return true
            }

            return false
        }
        guard let userdata = ghostty_surface_userdata(target.target.surface) else { return false }
        let surfaceView = Unmanaged<GhosttyNSView>.fromOpaque(userdata).takeUnretainedValue()

        switch action.tag {
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = splitDirection(from: action.action.new_split),
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            return performOnMain {
                tabManager.newSplit(tabId: tabId, surfaceId: surfaceId, direction: direction)
            }
        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = focusDirection(from: action.action.goto_split),
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            return performOnMain {
                tabManager.moveSplitFocus(tabId: tabId, surfaceId: surfaceId, direction: direction)
            }
        case GHOSTTY_ACTION_RESIZE_SPLIT:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let direction = resizeDirection(from: action.action.resize_split.direction),
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            let amount = action.action.resize_split.amount
            return performOnMain {
                tabManager.resizeSplit(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    direction: direction,
                    amount: amount
                )
            }
        case GHOSTTY_ACTION_EQUALIZE_SPLITS:
            guard let tabId = surfaceView.tabId,
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            return performOnMain {
                tabManager.equalizeSplits(tabId: tabId)
            }
        case GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id,
                  let tabManager = AppDelegate.shared?.tabManager else {
                return false
            }
            return performOnMain {
                tabManager.toggleSplitZoom(tabId: tabId, surfaceId: surfaceId)
            }
        case GHOSTTY_ACTION_SCROLLBAR:
            let scrollbar = GhosttyScrollbar(c: action.action.scrollbar)
            surfaceView.scrollbar = scrollbar
            NotificationCenter.default.post(
                name: .ghosttyDidUpdateScrollbar,
                object: surfaceView,
                userInfo: [GhosttyNotificationKey.scrollbar: scrollbar]
            )
            return true
        case GHOSTTY_ACTION_CELL_SIZE:
            let cellSize = CGSize(
                width: CGFloat(action.action.cell_size.width),
                height: CGFloat(action.action.cell_size.height)
            )
            surfaceView.cellSize = cellSize
            NotificationCenter.default.post(
                name: .ghosttyDidUpdateCellSize,
                object: surfaceView,
                userInfo: [GhosttyNotificationKey.cellSize: cellSize]
            )
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let needle = action.action.start_search.needle.flatMap { String(cString: $0) }
            DispatchQueue.main.async {
                if let searchState = terminalSurface.searchState {
                    if let needle, !needle.isEmpty {
                        searchState.needle = needle
                    }
                } else {
                    terminalSurface.searchState = TerminalSurface.SearchState(needle: needle ?? "")
                }
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: terminalSurface)
            }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            DispatchQueue.main.async {
                terminalSurface.searchState = nil
            }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let rawTotal = action.action.search_total.total
            let total: UInt? = rawTotal >= 0 ? UInt(rawTotal) : nil
            DispatchQueue.main.async {
                terminalSurface.searchState?.total = total
            }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let terminalSurface = surfaceView.terminalSurface else { return true }
            let rawSelected = action.action.search_selected.selected
            let selected: UInt? = rawSelected >= 0 ? UInt(rawSelected) : nil
            DispatchQueue.main.async {
                terminalSurface.searchState?.selected = selected
            }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            let title = action.action.set_title.title
                .flatMap { String(cString: $0) } ?? ""
            if let tabId = surfaceView.tabId {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: .ghosttyDidSetTitle,
                        object: surfaceView,
                        userInfo: [
                            GhosttyNotificationKey.tabId: tabId,
                            GhosttyNotificationKey.title: title,
                        ]
                    )
                }
            }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let tabId = surfaceView.tabId,
                  let surfaceId = surfaceView.terminalSurface?.id else { return true }
            let pwd = action.action.pwd.pwd.flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async {
                AppDelegate.shared?.tabManager?.updateSurfaceDirectory(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    directory: pwd
                )
            }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let tabId = surfaceView.tabId else { return true }
            let surfaceId = surfaceView.terminalSurface?.id
            let actionTitle = action.action.desktop_notification.title
                .flatMap { String(cString: $0) } ?? ""
            let actionBody = action.action.desktop_notification.body
                .flatMap { String(cString: $0) } ?? ""
            let tabTitle = AppDelegate.shared?.tabManager?.titleForTab(tabId) ?? "Terminal"
            let command = actionTitle.isEmpty ? tabTitle : actionTitle
            let body = actionBody
            DispatchQueue.main.async {
                AppDelegate.shared?.tabManager?.moveTabToTop(tabId)
                TerminalNotificationStore.shared.addNotification(
                    tabId: tabId,
                    surfaceId: surfaceId,
                    title: command,
                    subtitle: "",
                    body: body
                )
            }
            return true
        case GHOSTTY_ACTION_COLOR_CHANGE:
            if action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                let change = action.action.color_change
                surfaceView.backgroundColor = NSColor(
                    red: CGFloat(change.r) / 255,
                    green: CGFloat(change.g) / 255,
                    blue: CGFloat(change.b) / 255,
                    alpha: 1.0
                )
                surfaceView.applySurfaceBackground()
                if backgroundLogEnabled {
                    logBackground("OSC background change tab=\(surfaceView.tabId?.uuidString ?? "unknown") color=\(surfaceView.backgroundColor?.description ?? "nil")")
                }
                DispatchQueue.main.async {
                    surfaceView.applyWindowBackgroundIfActive()
                }
            }
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            updateDefaultBackground(from: action.action.config_change.config)
            DispatchQueue.main.async {
                surfaceView.applyWindowBackgroundIfActive()
            }
            return true
        case GHOSTTY_ACTION_KEY_SEQUENCE:
            return performOnMain {
                surfaceView.updateKeySequence(action.action.key_sequence)
                return true
            }
        case GHOSTTY_ACTION_KEY_TABLE:
            return performOnMain {
                surfaceView.updateKeyTable(action.action.key_table)
                return true
            }
        default:
            return false
        }
    }

    private func applyBackgroundToKeyWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        let color = defaultBackgroundColor.withAlphaComponent(defaultBackgroundOpacity)
        window.backgroundColor = color
        window.isOpaque = color.alphaComponent >= 1.0
        if backgroundLogEnabled {
            logBackground("applied default window background color=\(color) opacity=\(String(format: "%.3f", color.alphaComponent))")
        }
    }

    func logBackground(_ message: String) {
        let line = "cmux bg: \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: backgroundLogURL.path) == false {
                FileManager.default.createFile(atPath: backgroundLogURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: backgroundLogURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }
}

// MARK: - Terminal Surface (owns the ghostty_surface_t lifecycle)

enum CmuxdSurfaceState: Equatable {
    case disabled
    case connecting
    case ready
    case failed(String)

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

final class TerminalSurface: Identifiable, ObservableObject {
    private static let liveCountQueue = DispatchQueue(label: "cmuxterm.surface.count")
    private static var liveCount: Int = 0

    private static func bumpLiveCount(_ delta: Int) -> Int {
        liveCountQueue.sync {
            liveCount += delta
            return liveCount
        }
    }

    static func liveSurfaceCount() -> Int {
        liveCountQueue.sync { liveCount }
    }

    final class SearchState: ObservableObject {
        @Published var needle: String
        @Published var selected: UInt?
        @Published var total: UInt?

        init(needle: String = "") {
            self.needle = needle
            self.selected = nil
            self.total = nil
        }
    }

    private static let ioWriteCallback: ghostty_io_write_cb = { userdata, ptr, len in
        guard let userdata, let ptr, len > 0 else { return }
        let surface = Unmanaged<TerminalSurface>.fromOpaque(userdata).takeUnretainedValue()
        surface.handleIoWrite(ptr: ptr, len: len)
    }

    private(set) var surface: ghostty_surface_t?
    private var cmuxdPane: CmuxdPane?
    private(set) var sessionRef: CmuxdSessionRef?
    private var pendingInput: [Data] = []
    private var pendingOutput: [Data] = []
    private var outputBuffer: [Data] = []
    private var outputBufferIndex: Int = 0
    private var isOutputDraining: Bool = false
    private var pendingRefresh: Bool = false
    private var awaitingSnapshot: Bool = false
    private var hasProcessedOutput: Bool = false
    private var snapshotReplayBuffer: [Data] = []
    private var snapshotReplayActive: Bool = false
    private var snapshotReplayDeadline: Date?
    private var snapshotTimeoutWorkItem: DispatchWorkItem?
    private weak var attachedView: GhosttyNSView?
    private var cmuxdTimeoutWorkItem: DispatchWorkItem?
    private var cmuxdConnectStart: Date?
    private var cmuxdOverlayWorkItem: DispatchWorkItem?
    private let outputQueue = DispatchQueue(label: "cmuxd.output")
    private var pendingResize: PendingResize?
    private var resizeWorkItem: DispatchWorkItem?
    private var lastAppliedSize: CGSize = .zero
    private var lastAppliedScale: (x: CGFloat, y: CGFloat, layer: CGFloat) = (0, 0, 0)
    private let resizeCoalesceInterval: TimeInterval = 1.0 / 60.0
    let id: UUID
    let tabId: UUID
    private let surfaceContext: ghostty_surface_context_e
    private let configTemplate: ghostty_surface_config_s?
    private let workingDirectory: String?
    let hostedView: GhosttySurfaceScrollView
    private let surfaceView: GhosttyNSView
    @Published var cmuxdState: CmuxdSurfaceState = .disabled
    @Published var showCmuxdOverlay: Bool = false
    @Published var searchState: SearchState? = nil {
        didSet {
            if let searchState {
                hostedView.cancelFocusRequest()
                NSLog("Find: search state created tab=%@ surface=%@", tabId.uuidString, id.uuidString)
                searchNeedleCancellable = searchState.$needle
                    .removeDuplicates()
                    .map { needle -> AnyPublisher<String, Never> in
                        if needle.isEmpty || needle.count >= 3 {
                            return Just(needle).eraseToAnyPublisher()
                        }

                        return Just(needle)
                            .delay(for: .milliseconds(300), scheduler: DispatchQueue.main)
                            .eraseToAnyPublisher()
                    }
                    .switchToLatest()
                    .sink { [weak self] needle in
                        NSLog("Find: needle updated tab=%@ surface=%@ needle=%@", self?.tabId.uuidString ?? "unknown", self?.id.uuidString ?? "unknown", needle)
                        _ = self?.performBindingAction("search:\(needle)")
                    }
            } else if oldValue != nil {
                searchNeedleCancellable = nil
                NSLog("Find: search state cleared tab=%@ surface=%@", tabId.uuidString, id.uuidString)
                _ = performBindingAction("end_search")
            }
        }
    }
    private var searchNeedleCancellable: AnyCancellable?
    private struct PendingResize {
        let size: CGSize
        let xScale: CGFloat
        let yScale: CGFloat
        let layerScale: CGFloat
    }

    init(
        tabId: UUID,
        context: ghostty_surface_context_e,
        configTemplate: ghostty_surface_config_s?,
        workingDirectory: String? = nil,
        sessionRef: CmuxdSessionRef? = nil
    ) {
        self.id = UUID()
        self.tabId = tabId
        self.surfaceContext = context
        self.configTemplate = configTemplate
        self.workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionRef = sessionRef
        let view = GhosttyNSView(frame: .zero)
        self.surfaceView = view
        self.hostedView = GhosttySurfaceScrollView(surfaceView: view)
        if CmuxdManager.shared.connection(for: sessionRef?.connectionId) != nil {
            setCmuxdState(.connecting)
        }
        // Surface is created when attached to a view
        hostedView.attachSurface(self)
#if DEBUG
        let liveCount = Self.bumpLiveCount(1)
        let sessionLabel = sessionRef?.sessionId ?? sessionRef?.paneId ?? "nil"
        let connectionLabel = sessionRef?.connectionId ?? "local"
        MemoryLogStore.shared.append(
            "surface create id=\(id.uuidString) tab=\(tabId.uuidString) live=\(liveCount) session=\(sessionLabel) conn=\(connectionLabel)"
        )
#endif
    }

    private func scaleFactors(for view: GhosttyNSView) -> (x: CGFloat, y: CGFloat, layer: CGFloat) {
        let layerScale = view.window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        return (layerScale, layerScale, layerScale)
    }

    func attachToView(_ view: GhosttyNSView) {
        // If already attached to this view, nothing to do
        if attachedView === view && surface != nil {
            updateMetalLayer(for: view)
            return
        }

        if let attachedView, attachedView !== view {
            return
        }

        attachedView = view

        // If surface doesn't exist yet, create it
        if surface == nil {
            createSurface(for: view)
        }
    }

    private func createSurface(for view: GhosttyNSView) {
        guard let app = GhosttyApp.shared.app else {
            print("Ghostty app not initialized")
            return
        }

        let scaleFactors = scaleFactors(for: view)

        updateMetalLayer(for: view)

        var surfaceConfig = configTemplate ?? ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.userdata = Unmanaged.passUnretained(view).toOpaque()
        surfaceConfig.scale_factor = scaleFactors.layer
        surfaceConfig.context = surfaceContext
        if CmuxdManager.shared.isEnabled {
            surfaceConfig.io_mode = GHOSTTY_SURFACE_IO_MANUAL
            surfaceConfig.io_write_cb = TerminalSurface.ioWriteCallback
            surfaceConfig.io_write_userdata = Unmanaged.passUnretained(self).toOpaque()
        }
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        defer {
            for (key, value) in envStorage {
                free(key)
                free(value)
            }
        }

        var env: [String: String] = [:]
        if surfaceConfig.env_var_count > 0, let existingEnv = surfaceConfig.env_vars {
            let count = Int(surfaceConfig.env_var_count)
            if count > 0 {
                for i in 0..<count {
                    let item = existingEnv[i]
                    if let key = String(cString: item.key, encoding: .utf8),
                       let value = String(cString: item.value, encoding: .utf8) {
                        env[key] = value
                    }
                }
            }
        }

        env["CMUX_PANEL_ID"] = id.uuidString
        env["CMUX_TAB_ID"] = tabId.uuidString
        env["CMUX_SOCKET_PATH"] = SocketControlSettings.socketPath()

        if let cliBinPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            let currentPath = env["PATH"]
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            if !currentPath.split(separator: ":").contains(Substring(cliBinPath)) {
                let separator = currentPath.isEmpty ? "" : ":"
                env["PATH"] = "\(cliBinPath)\(separator)\(currentPath)"
            }
        }

        if !env.isEmpty {
            envVars.reserveCapacity(env.count)
            envStorage.reserveCapacity(env.count)
            for (key, value) in env {
                guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
                envStorage.append((keyPtr, valuePtr))
                envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
            }
        }

        let createSurface = { [self] in
            if !envVars.isEmpty {
                let envVarsCount = envVars.count
                envVars.withUnsafeMutableBufferPointer { buffer in
                    surfaceConfig.env_vars = buffer.baseAddress
                    surfaceConfig.env_var_count = envVarsCount
                    self.surface = ghostty_surface_new(app, &surfaceConfig)
                }
            } else {
                self.surface = ghostty_surface_new(app, &surfaceConfig)
            }
        }

        if let workingDirectory, !workingDirectory.isEmpty {
            workingDirectory.withCString { cWorkingDir in
                surfaceConfig.working_directory = cWorkingDir
                createSurface()
            }
        } else {
            createSurface()
        }

        if surface == nil {
            print("Failed to create ghostty surface")
            return
        }

        ghostty_surface_set_content_scale(surface, scaleFactors.x, scaleFactors.y)
        ghostty_surface_set_size(
            surface,
            UInt32(view.bounds.width * scaleFactors.x),
            UInt32(view.bounds.height * scaleFactors.y)
        )
        ghostty_surface_refresh(surface)
        attachCmuxdIfNeeded()
    }

    private func updateMetalLayer(for view: GhosttyNSView) {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.contentsScale = scale
            if view.bounds.width > 0 && view.bounds.height > 0 {
                metalLayer.drawableSize = CGSize(
                    width: view.bounds.width * scale,
                    height: view.bounds.height * scale
                )
            }
        }
    }

    func updateSize(width: CGFloat, height: CGFloat, xScale: CGFloat, yScale: CGFloat, layerScale: CGFloat) {
        pendingResize = PendingResize(
            size: CGSize(width: width, height: height),
            xScale: xScale,
            yScale: yScale,
            layerScale: layerScale
        )
        guard resizeWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            resizeWorkItem = nil
            guard let pending = pendingResize else { return }
            pendingResize = nil
            applyPendingResize(pending)
        }
        resizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + resizeCoalesceInterval, execute: workItem)
    }

    private func applyPendingResize(_ pending: PendingResize) {
        guard let surface = surface else { return }
        let sizeChanged = pending.size != lastAppliedSize
        let scaleChanged = pending.xScale != lastAppliedScale.x || pending.yScale != lastAppliedScale.y
        let layerChanged = pending.layerScale != lastAppliedScale.layer

        if sizeChanged || scaleChanged {
            ghostty_surface_set_content_scale(surface, pending.xScale, pending.yScale)
            ghostty_surface_set_size(
                surface,
                UInt32(pending.size.width * pending.xScale),
                UInt32(pending.size.height * pending.yScale)
            )
            ghostty_surface_refresh(surface)
            lastAppliedSize = pending.size
            lastAppliedScale = (pending.xScale, pending.yScale, pending.layerScale)
            sendResizeToCmuxd()
        } else if layerChanged {
            lastAppliedScale.layer = pending.layerScale
        }

        if let view = attachedView, let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.contentsScale = pending.layerScale
            metalLayer.drawableSize = CGSize(
                width: pending.size.width * pending.layerScale,
                height: pending.size.height * pending.layerScale
            )
        }
    }

    private func attachCmuxdIfNeeded() {
        guard CmuxdManager.shared.isEnabled else { return }
        guard cmuxdPane == nil else { return }
        CmuxdManager.shared.startIfNeeded()
        guard let connection = CmuxdManager.shared.connection(for: sessionRef?.connectionId) else { return }

        if cmuxdConnectStart == nil {
            cmuxdConnectStart = Date()
        }
        setCmuxdState(.connecting)
        scheduleCmuxdTimeout()

        let requestedSessionId = sessionRef?.sessionId ?? sessionRef?.paneId
        let shouldRequestSnapshot = requestedSessionId != nil
        outputQueue.sync { [weak self] in
            guard let self else { return }
            awaitingSnapshot = shouldRequestSnapshot
            if shouldRequestSnapshot {
                pendingOutput.removeAll()
                outputBuffer.removeAll()
                outputBufferIndex = 0
                isOutputDraining = false
                pendingRefresh = false
                hasProcessedOutput = false
                snapshotReplayBuffer.removeAll()
                snapshotReplayActive = false
                snapshotReplayDeadline = nil
            }
        }
        if shouldRequestSnapshot {
            scheduleSnapshotTimeout()
        }
        let attachPane: (CmuxdPane) -> Void = { [weak self] pane in
            guard let self else { return }
            self.cmuxdPane = pane
            self.markCmuxdReady()
            let updatedRef = CmuxdSessionRef(
                connectionId: connection.id,
                sessionId: pane.sessionId ?? requestedSessionId,
                paneId: pane.id
            )
            self.sessionRef = updatedRef
            AppDelegate.shared?.tabManager?.updateSurfaceSessionRef(
                tabId: self.tabId,
                surfaceId: self.id,
                sessionRef: updatedRef
            )
#if DEBUG
            MemoryLogStore.shared.append(
                "surface attach id=\(self.id.uuidString) tab=\(self.tabId.uuidString) pane=\(pane.id) session=\(updatedRef.sessionId ?? "nil") conn=\(updatedRef.connectionId)"
            )
#endif
            pane.onOutput = { [weak self] data in
                self?.enqueueOutput(data)
            }
            pane.onSnapshot = { [weak self] data, _, _ in
                self?.enqueueSnapshot(data)
            }
            pane.onExit = { [weak self] _ in
                guard let self else { return }
                self.resetOutputState()
                DispatchQueue.main.async {
                    _ = AppDelegate.shared?.tabManager?.closeSurface(tabId: self.tabId, surfaceId: self.id)
                }
            }
            pane.onTitle = { [weak self] title in
                guard let self else { return }
                NotificationCenter.default.post(
                    name: .ghosttyDidSetTitle,
                    object: self,
                    userInfo: [
                        GhosttyNotificationKey.tabId: self.tabId,
                        GhosttyNotificationKey.title: title,
                    ]
                )
            }
            pane.onCwd = { [weak self] cwd in
                guard let self else { return }
                let normalized = self.normalizeRemoteCwd(cwd)
                AppDelegate.shared?.tabManager?.updateSurfaceDirectory(
                    tabId: self.tabId,
                    surfaceId: self.id,
                    directory: normalized
                )
            }
            pane.onNotify = { [weak self] title, body in
                guard let self else { return }
                let tabTitle = AppDelegate.shared?.tabManager?.titleForTab(self.tabId) ?? "Terminal"
                let command = title.isEmpty ? tabTitle : title
                let sessionLabel = pane.sessionId.map { String($0.prefix(8)) } ?? "session"
                let subtitle = "\(pane.connectionLabel) · \(sessionLabel)"
                AppDelegate.shared?.tabManager?.moveTabToTop(self.tabId)
                TerminalNotificationStore.shared.addNotification(
                    tabId: self.tabId,
                    surfaceId: self.id,
                    title: command,
                    subtitle: subtitle,
                    body: body
                )
            }
            self.sendResizeToCmuxd()
            self.scheduleDelayedResize()
            self.flushPendingInput()
            if shouldRequestSnapshot {
                pane.requestSnapshot()
            }
        }

        if let sessionId = requestedSessionId {
            connection.attachSession(id: sessionId, completion: attachPane)
        } else {
            var cols: Int?
            var rows: Int?
            if let surface {
                let size = ghostty_surface_size(surface)
                if size.columns > 0 && size.rows > 0 {
                    cols = Int(size.columns)
                    rows = Int(size.rows)
                }
            }
            let options = CmuxdConnection.SessionRequestOptions(
                cwd: workingDirectory,
                term: "xterm-ghostty",
                cols: cols,
                rows: rows
            )
            connection.requestSession(options: options, completion: attachPane)
        }
    }

    private func normalizeRemoteCwd(_ cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let url = URL(string: trimmed), url.isFileURL {
            return url.path
        }
        if trimmed.hasPrefix("kitty-shell-cwd://") {
            let replaced = trimmed.replacingOccurrences(of: "kitty-shell-cwd://", with: "file://")
            if let url = URL(string: replaced), url.isFileURL {
                return url.path
            }
        }
        return trimmed
    }

    fileprivate func scheduleDelayedResize() {
        let delays: [TimeInterval] = [0.1, 0.4]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.sendResizeToCmuxd()
            }
        }
    }

    private func handleIoWrite(ptr: UnsafePointer<CChar>, len: UInt) {
        let data = Data(bytes: ptr, count: Int(len))
        if let pane = cmuxdPane {
            pane.sendInput(data)
        } else {
            pendingInput.append(data)
        }
    }

    private func flushPendingInput() {
        guard let pane = cmuxdPane else { return }
        guard !pendingInput.isEmpty else { return }
        for data in pendingInput {
            pane.sendInput(data)
        }
        pendingInput.removeAll()
    }

    private func sendResizeToCmuxd() {
        guard let pane = cmuxdPane else { return }
        guard let surface else { return }
        let size = ghostty_surface_size(surface)
        pane.sendResize(cols: Int(size.columns), rows: Int(size.rows))
    }

    private func enqueueOutput(_ data: Data) {
        outputQueue.async { [weak self] in
            self?.handleOutputLocked(data)
        }
    }

    private func enqueueSnapshot(_ data: Data) {
        outputQueue.async { [weak self] in
            self?.handleSnapshotLocked(data)
        }
    }

    private func handleOutputLocked(_ data: Data) {
        if awaitingSnapshot {
            pendingOutput.append(data)
            return
        }
        if snapshotReplayActive {
            snapshotReplayBuffer.append(data)
            if let deadline = snapshotReplayDeadline, Date() > deadline {
                snapshotReplayActive = false
                snapshotReplayDeadline = nil
                snapshotReplayBuffer.removeAll()
            }
        }
        outputBuffer.append(data)
        scheduleOutputDrain()
    }

    private func handleSnapshotLocked(_ data: Data) {
        snapshotTimeoutWorkItem?.cancel()
        if awaitingSnapshot {
            awaitingSnapshot = false
            processOutputLocked(data)
            flushPendingOutputLocked()
            if let cursorSeq = configuredCursorStyleSequence() {
                processOutputLocked(cursorSeq)
            }
        } else {
            if snapshotReplayActive {
                let withinDeadline = snapshotReplayDeadline.map { Date() <= $0 } ?? true
                if withinDeadline {
                    let replay = snapshotReplayBuffer
                    snapshotReplayBuffer.removeAll()
                    snapshotReplayActive = false
                    snapshotReplayDeadline = nil
                    processOutputLocked(data)
                    if let cursorSeq = configuredCursorStyleSequence() {
                        processOutputLocked(cursorSeq)
                    }
                    for chunk in replay {
                        processOutputLocked(chunk)
                    }
                    return
                }
                snapshotReplayActive = false
                snapshotReplayDeadline = nil
                snapshotReplayBuffer.removeAll()
            }
            if !hasProcessedOutput {
                processOutputLocked(data)
                flushPendingOutputLocked()
                return
            }
            // Late snapshot after live output started; apply cursor style only.
            if let cursorSeq = extractCursorStyleSequence(from: data) {
                processOutputLocked(cursorSeq)
            }
        }
    }

    private func scheduleOutputDrain() {
        guard !isOutputDraining else { return }
        isOutputDraining = true
        drainOutputLocked()
    }

    private func drainOutputLocked() {
        while outputBufferIndex < outputBuffer.count {
            let chunk = outputBuffer[outputBufferIndex]
            outputBufferIndex += 1
            processOutputLocked(chunk)
        }
        outputBuffer.removeAll(keepingCapacity: true)
        outputBufferIndex = 0
        isOutputDraining = false
    }

    private func processOutputLocked(_ data: Data) {
        guard let surface else { return }
        markCmuxdReady()
        hasProcessedOutput = true
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_process_output(surface, base, UInt(data.count))
        }
        scheduleRefreshLocked()
    }

    private func scheduleRefreshLocked() {
        guard !pendingRefresh else { return }
        pendingRefresh = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            guard let self, let surface = self.surface else { return }
            ghostty_surface_refresh(surface)
            self.outputQueue.async { [weak self] in
                self?.pendingRefresh = false
            }
        }
    }

    private func flushPendingOutputLocked() {
        guard !pendingOutput.isEmpty else { return }
        for data in pendingOutput {
            outputBuffer.append(data)
        }
        pendingOutput.removeAll()
        scheduleOutputDrain()
    }

    func applyWindowBackgroundIfActive() {
        surfaceView.applyWindowBackgroundIfActive()
    }

    func closeRemote() {
        cmuxdPane?.close()
        cmuxdPane = nil
        pendingInput.removeAll()
        resetOutputState()
        snapshotTimeoutWorkItem?.cancel()
        cmuxdTimeoutWorkItem?.cancel()
        cmuxdConnectStart = nil
#if DEBUG
        MemoryLogStore.shared.append(
            "surface closeRemote id=\(id.uuidString) tab=\(tabId.uuidString) pending_in=\(pendingInput.count) pending_out=\(pendingOutput.count)"
        )
#endif
    }

    func retryCmuxd() {
        cmuxdPane = nil
        pendingInput.removeAll()
        resetOutputState()
        snapshotTimeoutWorkItem?.cancel()
        cmuxdTimeoutWorkItem?.cancel()
        cmuxdConnectStart = nil
        CmuxdManager.shared.startIfNeeded()
        CmuxdManager.shared.connection(for: sessionRef?.connectionId)?.connectIfNeeded()
        attachCmuxdIfNeeded()
    }

    func setFocus(_ focused: Bool) {
        guard let surface = surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    func needsConfirmClose() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    func sendText(_ text: String) {
        guard let surface = surface else { return }
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
            ghostty_surface_text(surface, baseAddress, UInt(rawBuffer.count))
        }
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    func hasSelection() -> Bool {
        guard let surface = surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    deinit {
        if let surface = surface {
            ghostty_surface_free(surface)
        }
#if DEBUG
        let liveCount = Self.bumpLiveCount(-1)
        let sessionLabel = sessionRef?.sessionId ?? sessionRef?.paneId ?? "nil"
        let connectionLabel = sessionRef?.connectionId ?? "local"
        MemoryLogStore.shared.append(
            "surface deinit id=\(id.uuidString) tab=\(tabId.uuidString) live=\(liveCount) session=\(sessionLabel) conn=\(connectionLabel)"
        )
#endif
    }

    private func resetOutputState() {
        outputQueue.async { [weak self] in
            guard let self else { return }
            pendingOutput.removeAll()
            outputBuffer.removeAll()
            outputBufferIndex = 0
            isOutputDraining = false
            pendingRefresh = false
            awaitingSnapshot = false
            hasProcessedOutput = false
            snapshotReplayBuffer.removeAll()
            snapshotReplayActive = false
            snapshotReplayDeadline = nil
        }
    }

    private func extractCursorStyleSequence(from data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        guard let qIndex = bytes.lastIndex(of: UInt8(ascii: "q")),
              qIndex == bytes.count - 1 else {
            return nil
        }
        guard let escIndex = bytes[..<qIndex].lastIndex(of: 0x1B) else {
            return nil
        }
        let seq = bytes[escIndex...]
        guard seq.count >= 4, seq.count <= 8 else { return nil }
        guard seq.count >= 3, seq[1] == UInt8(ascii: "[") else { return nil }
        guard seq[seq.count - 2] == 0x20 else { return nil }
        return Data(seq)
    }

    private func configuredCursorStyleSequence() -> Data? {
        guard let config = GhosttyApp.shared.config else { return nil }
        var stylePtr: UnsafePointer<Int8>? = nil
        let styleKey = "cursor-style"
        guard ghostty_config_get(config, &stylePtr, styleKey, UInt(styleKey.lengthOfBytes(using: .utf8))),
              let cString = stylePtr else {
            return nil
        }
        let style = String(cString: cString).lowercased()
        if style.isEmpty {
            return nil
        }
        var blink = true
        let blinkKey = "cursor-style-blink"
        _ = ghostty_config_get(config, &blink, blinkKey, UInt(blinkKey.lengthOfBytes(using: .utf8)))

        let code: Int
        switch style {
        case "block":
            code = blink ? 1 : 2
        case "underline":
            code = blink ? 3 : 4
        case "bar":
            code = blink ? 5 : 6
        default:
            return nil
        }

        return Data("\u{1b}[\(code) q".utf8)
    }

    private func scheduleCmuxdTimeout() {
        cmuxdTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.cmuxdPane == nil {
                let start = self.cmuxdConnectStart ?? Date()
                let elapsed = Date().timeIntervalSince(start)
                let connection = CmuxdManager.shared.connection(for: self.sessionRef?.connectionId)
                let state = connection?.stateSnapshot()
                let localReady = CmuxdManager.shared.isLocalReadySnapshot()
                let shouldKeepWaiting: Bool = {
                    switch state {
                    case .connecting, .ready:
                        return elapsed < 30.0
                    case .failed:
                        return localReady && elapsed < 30.0
                    case .disconnected, .none:
                        return localReady && elapsed < 30.0
                    }
                }()
                if shouldKeepWaiting {
                    self.scheduleCmuxdTimeout()
                    return
                }
                var message = "Unable to connect to cmuxd"
                if case let .failed(reason)? = state {
                    message += "\n\(reason)"
                }
                if let detail = CmuxdManager.shared.describeFailure() {
                    message += "\n\(detail)"
                }
                self.setCmuxdState(.failed(message))
            }
        }
        cmuxdTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: item)
    }

    private func scheduleSnapshotTimeout() {
        snapshotTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.outputQueue.async { [weak self] in
                guard let self else { return }
                if self.awaitingSnapshot {
                    self.awaitingSnapshot = false
                    self.snapshotReplayBuffer = self.pendingOutput
                    self.snapshotReplayActive = true
                    self.snapshotReplayDeadline = Date().addingTimeInterval(2.0)
                    self.flushPendingOutputLocked()
                }
            }
        }
        snapshotTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: item)
    }

    private func markCmuxdReady() {
        if cmuxdState == .ready { return }
        cmuxdTimeoutWorkItem?.cancel()
        if let start = cmuxdConnectStart {
            let elapsed = Date().timeIntervalSince(start)
            CmuxdManager.logTiming(String(format: "surface ready tab=%@ surface=%@ after %.3fs",
                                          self.tabId.uuidString, self.id.uuidString, elapsed))
        }
        cmuxdConnectStart = nil
        setCmuxdState(.ready)
    }

    private func setCmuxdState(_ state: CmuxdSurfaceState) {
        let apply = { [weak self] in
            guard let self else { return }
            self.cmuxdState = state
            switch state {
            case .connecting:
                self.scheduleCmuxdOverlay()
            case .disabled, .ready, .failed:
                self.cmuxdOverlayWorkItem?.cancel()
                self.cmuxdOverlayWorkItem = nil
                self.showCmuxdOverlay = false
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    private func scheduleCmuxdOverlay() {
        cmuxdOverlayWorkItem?.cancel()
        showCmuxdOverlay = false
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.cmuxdState.isConnecting else { return }
            self.showCmuxdOverlay = true
        }
        cmuxdOverlayWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }
}

// MARK: - Ghostty Surface View

class GhosttyNSView: NSView, NSUserInterfaceValidations {
    private static let focusDebugEnabled: Bool = {
        if ProcessInfo.processInfo.environment["CMUX_FOCUS_DEBUG"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "cmuxFocusDebug")
    }()
    fileprivate static func focusLog(_ message: String) {
        guard focusDebugEnabled else { return }
        FocusLogStore.shared.append(message)
        NSLog("[FOCUSDBG] %@", message)
    }

    weak var terminalSurface: TerminalSurface?
    private var surfaceAttached = false
    var scrollbar: GhosttyScrollbar?
    var cellSize: CGSize = .zero
    var desiredFocus: Bool = false
    var tabId: UUID?
    var onFocus: (() -> Void)?
    var onTriggerFlash: (() -> Void)?
    var backgroundColor: NSColor?
    private var keySequence: [ghostty_input_trigger_s] = []
    private var keyTables: [String] = []
    private var eventMonitor: Any?
    private var trackingArea: NSTrackingArea?
    private var windowObserver: NSObjectProtocol?
    private var lastSurfaceSize: CGSize = .zero
    private var lastContentScale: CGSize = .zero
    private var lastLayerScale: CGFloat = 0
    private var hasSurfaceMetrics = false
    private var lastScrollEventTime: CFTimeInterval = 0
    private var suppressResizeUpdates = false

    override func makeBackingLayer() -> CALayer {
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        return metalLayer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        installEventMonitor()
        updateTrackingAreas()
    }

    private func effectiveBackgroundColor() -> NSColor {
        let base = backgroundColor ?? GhosttyApp.shared.defaultBackgroundColor
        let opacity = GhosttyApp.shared.defaultBackgroundOpacity
        return base.withAlphaComponent(opacity)
    }

    func applySurfaceBackground() {
        let color = effectiveBackgroundColor()
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.backgroundColor = color.cgColor
            metalLayer.isOpaque = color.alphaComponent >= 1.0
        }
        terminalSurface?.hostedView.setBackgroundColor(color)
    }

    func applyWindowBackgroundIfActive() {
        guard let window else { return }
        if let tabId, let selectedId = AppDelegate.shared?.tabManager?.selectedTabId, tabId != selectedId {
            return
        }
        applySurfaceBackground()
        let color = effectiveBackgroundColor()
        window.backgroundColor = color
        window.isOpaque = color.alphaComponent >= 1.0
        if GhosttyApp.shared.backgroundLogEnabled {
            GhosttyApp.shared.logBackground("applied window background tab=\(tabId?.uuidString ?? "unknown") color=\(color) opacity=\(String(format: "%.3f", color.alphaComponent))")
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            return self?.localEventHandler(event) ?? event
        }
    }

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .scrollWheel:
            return localEventScrollWheel(event)
        default:
            return event
        }
    }

    private func localEventScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard let window,
              let eventWindow = event.window,
              window == eventWindow else { return event }

        let location = convert(event.locationInWindow, from: nil)
        guard hitTest(location) == self else { return event }

        Self.focusLog("localEventScrollWheel: window=\(ObjectIdentifier(window)) firstResponder=\(String(describing: window.firstResponder))")
        return event
    }

    func attachSurface(_ surface: TerminalSurface) {
        terminalSurface = surface
        tabId = surface.tabId
        surfaceAttached = false
        hasSurfaceMetrics = false
        attachSurfaceIfNeeded()
    }

    private func attachSurfaceIfNeeded() {
        guard !surfaceAttached else { return }
        guard let terminalSurface = terminalSurface else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }
        guard window != nil else { return }

        surfaceAttached = true
        terminalSurface.attachToView(self)
        terminalSurface.setFocus(desiredFocus)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        if let window {
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] notification in
                self?.windowDidChangeScreen(notification)
            }
            attachSurfaceIfNeeded()
            updateSurfaceSize()
            applySurfaceBackground()
            applyWindowBackgroundIfActive()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        updateSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        attachSurfaceIfNeeded()
        updateSurfaceSize()
    }

    override func layout() {
        super.layout()
        attachSurfaceIfNeeded()
    }

    override var isOpaque: Bool { false }

    private func updateSurfaceSize() {
        guard !suppressResizeUpdates else { return }
        guard let terminalSurface = terminalSurface else { return }
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let layerScale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let xScale = layerScale
        let yScale = layerScale
        if hasSurfaceMetrics {
            let sameSize = nearlyEqual(lastSurfaceSize.width, bounds.width, epsilon: 0.01)
                && nearlyEqual(lastSurfaceSize.height, bounds.height, epsilon: 0.01)
            let sameScale = nearlyEqual(lastContentScale.width, xScale)
                && nearlyEqual(lastContentScale.height, yScale)
                && nearlyEqual(lastLayerScale, layerScale)
            if sameSize && sameScale {
                return
            }
        }
        lastSurfaceSize = bounds.size
        lastContentScale = CGSize(width: xScale, height: yScale)
        lastLayerScale = layerScale
        hasSurfaceMetrics = true
        terminalSurface.updateSize(
            width: bounds.width,
            height: bounds.height,
            xScale: xScale,
            yScale: yScale,
            layerScale: layerScale
        )
    }

    func setResizeSuspended(_ suspended: Bool) {
        guard suppressResizeUpdates != suspended else { return }
        suppressResizeUpdates = suspended
        if !suspended {
            updateSurfaceSize()
        }
    }

    private func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    // Convenience accessor for the ghostty surface
    private var surface: ghostty_surface_t? {
        terminalSurface?.surface
    }

    func performBindingAction(_ action: String) -> Bool {
        guard let surface = surface else { return false }
        return action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(strlen(cString)))
        }
    }

    // MARK: - Input Handling

    @IBAction func copy(_ sender: Any?) {
        _ = performBindingAction("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        _ = performBindingAction("paste_from_clipboard")
    }

    @IBAction func pasteAsPlainText(_ sender: Any?) {
        _ = performBindingAction("paste_from_clipboard")
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            guard let surface = surface else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)), #selector(pasteAsPlainText(_:)):
            return GhosttyPasteboardHelper.hasString(for: GHOSTTY_CLIPBOARD_STANDARD)
        default:
            return true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface = surface {
            let now = CACurrentMediaTime()
            let deltaMs = (now - lastScrollEventTime) * 1000
            Self.focusLog("becomeFirstResponder: surface=\(terminalSurface?.id.uuidString ?? "nil") deltaSinceScrollMs=\(String(format: "%.2f", deltaMs))")
            onFocus?()
#if DEBUG
            if let terminalSurface {
                AppDelegate.shared?.recordJumpUnreadFocusIfExpected(
                    tabId: terminalSurface.tabId,
                    surfaceId: terminalSurface.id
                )
            }
#endif
            ghostty_surface_set_focus(surface, true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        return super.resignFirstResponder()
    }

    // For NSTextInputClient - accumulates text during key events
    private var keyTextAccumulator: [String]? = nil
    private var markedText = NSMutableAttributedString()
    private var lastPerformKeyEvent: TimeInterval?

    // Prevents NSBeep for unimplemented actions from interpretKeyEvents
    override func doCommand(by selector: Selector) {
        // Intentionally empty - prevents system beep on unhandled key commands
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        guard window?.firstResponder === self else { return false }
        guard let surface = surface else { return false }

        // Check if this event matches a Ghostty keybinding.
        let bindingFlags: ghostty_binding_flags_e? = {
            var keyEvent = ghosttyKeyEvent(for: event, surface: surface)
            let text = event.characters ?? ""
            var flags = ghostty_binding_flags_e(0)
            let isBinding = text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
            }
            return isBinding ? flags : nil
        }()

        if let bindingFlags {
            let isConsumed = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_CONSUMED.rawValue) != 0
            let isAll = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_ALL.rawValue) != 0
            let isPerformable = (bindingFlags.rawValue & GHOSTTY_BINDING_FLAGS_PERFORMABLE.rawValue) != 0

            // If the binding is consumed and not meant for the menu, allow menu first.
            if isConsumed && !isAll && !isPerformable && keySequence.isEmpty && keyTables.isEmpty {
                if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
                    return true
                }
            }

            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass Ctrl+Return through verbatim (prevent context menu equivalent).
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            // Treat Ctrl+/ as Ctrl+_ to avoid the system beep.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else {
                return false
            }
            equivalent = "_"

        default:
            // Ignore synthetic events.
            if event.timestamp == 0 {
                return false
            }

            // Only handle command/control-modified keys here.
            if !event.modifierFlags.contains(.command) &&
                !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }

            if let lastPerformKeyEvent {
                self.lastPerformKeyEvent = nil
                if lastPerformKeyEvent == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }

            lastPerformKeyEvent = event.timestamp
            return false
        }

        let finalEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        )

        if let finalEvent {
            keyDown(with: finalEvent)
            return true
        }

        return false
    }

    override func keyDown(with event: NSEvent) {
        guard let surface = surface else {
            super.keyDown(with: event)
            return
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt)
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        // Set up text accumulator for interpretKeyEvents
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        // Let the input system handle the event (for IME, dead keys, etc.)
        interpretKeyEvents([translationEvent])

        // Build the key event
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        // Control and Command never contribute to text translation
        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.composing = markedText.length > 0
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

        // Use accumulated text from insertText (for IME), or compute text for key
        if let accumulated = keyTextAccumulator, !accumulated.isEmpty {
            for text in accumulated {
                if shouldSendText(text) {
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        _ = ghostty_surface_key(surface, keyEvent)
                    }
                } else {
                    keyEvent.text = nil
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            }
        } else {
            // Get the appropriate text for this key event
            // For control characters, this returns the unmodified character
            // so Ghostty's KeyEncoder can handle ctrl encoding
            if let text = textForKeyEvent(translationEvent) {
                if shouldSendText(text) {
                    text.withCString { ptr in
                        keyEvent.text = ptr
                        _ = ghostty_surface_key(surface, keyEvent)
                    }
                } else {
                    keyEvent.text = nil
                    _ = ghostty_surface_key(surface, keyEvent)
                }
            } else {
                keyEvent.text = nil
                _ = ghostty_surface_key(surface, keyEvent)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = surface else {
            super.keyUp(with: event)
            return
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = ghostty_surface_key(surface, keyEvent)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else {
            super.flagsChanged(with: event)
            return
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.composing = false
        _ = ghostty_surface_key(surface, keyEvent)
    }

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if event.modifierFlags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if event.modifierFlags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if event.modifierFlags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if event.modifierFlags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Consumed mods are modifiers that were used for text translation.
    /// Control and Command never contribute to text translation, so they
    /// should be excluded from consumed_mods.
    private func consumedModsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        // Only include Shift and Option as potentially consumed
        // Control and Command are never consumed for text translation
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Get the characters for a key event with control character handling.
    /// When control is pressed, we get the character without the control modifier
    /// so Ghostty's KeyEncoder can apply its own control character encoding.
    private func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }

        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            // If we have a single control character, return the character without
            // the control modifier so Ghostty's KeyEncoder can handle it.
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            // Private Use Area characters (function keys) should not be sent
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return chars
    }

    /// Get the unshifted codepoint for the key event
    private func unshiftedCodepointFromEvent(_ event: NSEvent) -> UInt32 {
        guard let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    private func shouldSendText(_ text: String) -> Bool {
        guard let first = text.utf8.first else { return false }
        return first >= 0x20
    }

    private func ghosttyKeyEvent(for event: NSEvent, surface: ghostty_surface_t) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)

        // Translate mods to respect Ghostty config (e.g., macos-option-as-alt).
        let translationModsGhostty = ghostty_surface_key_translation_mods(surface, modsFromEvent(event))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            let hasFlag: Bool
            switch flag {
            case .shift:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SHIFT.rawValue) != 0
            case .control:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_CTRL.rawValue) != 0
            case .option:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_ALT.rawValue) != 0
            case .command:
                hasFlag = (translationModsGhostty.rawValue & GHOSTTY_MODS_SUPER.rawValue) != 0
            default:
                hasFlag = translationMods.contains(flag)
            }
            if hasFlag {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        keyEvent.consumed_mods = consumedModsFromFlags(translationMods)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)
        return keyEvent
    }

    func updateKeySequence(_ action: ghostty_action_key_sequence_s) {
        if action.active {
            keySequence.append(action.trigger)
        } else {
            keySequence.removeAll()
        }
    }

    func updateKeyTable(_ action: ghostty_action_key_table_s) {
        switch action.tag {
        case GHOSTTY_KEY_TABLE_ACTIVATE:
            let namePtr = action.value.activate.name
            let nameLen = Int(action.value.activate.len)
            if let namePtr, nameLen > 0 {
                let data = Data(bytes: namePtr, count: nameLen)
                if let name = String(data: data, encoding: .utf8) {
                    keyTables.append(name)
                }
            }
        case GHOSTTY_KEY_TABLE_DEACTIVATE:
            _ = keyTables.popLast()
        case GHOSTTY_KEY_TABLE_DEACTIVATE_ALL:
            keyTables.removeAll()
        default:
            break
        }
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        if !ghostty_surface_mouse_captured(surface) {
            super.rightMouseUp(with: event)
            return
        }

        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let surface = surface else { return nil }
        if ghostty_surface_mouse_captured(surface) {
            return nil
        }

        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))

        let menu = NSMenu()
        if onTriggerFlash != nil {
            let flashItem = menu.addItem(withTitle: "Trigger Flash", action: #selector(triggerFlash(_:)), keyEquivalent: "")
            flashItem.target = self
            menu.addItem(.separator())
        }
        if ghostty_surface_has_selection(surface) {
            let item = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            item.target = self
        }
        let pasteItem = menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        return menu
    }

    @objc private func triggerFlash(_ sender: Any?) {
        onTriggerFlash?()
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface = surface else { return }
        if NSEvent.pressedMouseButtons != 0 {
            return
        }
        ghostty_surface_mouse_pos(surface, -1, -1, modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }
        lastScrollEventTime = CACurrentMediaTime()
        Self.focusLog("scrollWheel: surface=\(terminalSurface?.id.uuidString ?? "nil") firstResponder=\(String(describing: window?.firstResponder))")
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }

        var mods: Int32 = 0
        if precision {
            mods |= 0b0000_0001
        }

        let momentum: Int32
        switch event.momentumPhase {
        case .began:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
        mods |= momentum << 1

        // Track scroll state for lag detection
        let hasMomentum = event.momentumPhase != [] && event.momentumPhase != .mayBegin
        let momentumEnded = event.momentumPhase == .ended || event.momentumPhase == .cancelled
        GhosttyApp.shared.markScrollActivity(hasMomentum: hasMomentum, momentumEnded: momentumEnded)

        ghostty_surface_mouse_scroll(
            surface,
            x,
            y,
            ghostty_input_scroll_mods_t(mods)
        )
    }

    deinit {
        // Surface lifecycle is managed by TerminalSurface, not the view
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
        terminalSurface = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ],
            owner: self,
            userInfo: nil
        )

        if let trackingArea {
            addTrackingArea(trackingArea)
        }
    }

    private func windowDidChangeScreen(_ notification: Notification) {
        guard let window else { return }
        guard let object = notification.object as? NSWindow, window == object else { return }
        guard let screen = window.screen else { return }
        guard let surface = terminalSurface?.surface else { return }

        ghostty_surface_set_display_id(surface, screen.displayID ?? 0)

        DispatchQueue.main.async { [weak self] in
            self?.viewDidChangeBackingProperties()
        }
    }
}

private extension NSScreen {
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}

struct GhosttyScrollbar {
    let total: UInt64
    let offset: UInt64
    let len: UInt64

    init(c: ghostty_action_scrollbar_s) {
        total = c.total
        offset = c.offset
        len = c.len
    }
}

enum GhosttyNotificationKey {
    static let scrollbar = "ghostty.scrollbar"
    static let cellSize = "ghostty.cellSize"
    static let tabId = "ghostty.tabId"
    static let title = "ghostty.title"
}

extension Notification.Name {
    static let ghosttyDidUpdateScrollbar = Notification.Name("ghosttyDidUpdateScrollbar")
    static let ghosttyDidUpdateCellSize = Notification.Name("ghosttyDidUpdateCellSize")
    static let ghosttySearchFocus = Notification.Name("ghosttySearchFocus")
}

// MARK: - Scroll View Wrapper (Ghostty-style scrollbar)

private final class GhosttyScrollView: NSScrollView {
    weak var surfaceView: GhosttyNSView?

    override func scrollWheel(with event: NSEvent) {
        guard let surfaceView else {
            super.scrollWheel(with: event)
            return
        }

        if let surface = surfaceView.terminalSurface?.surface,
           ghostty_surface_mouse_captured(surface) {
            GhosttyNSView.focusLog("GhosttyScrollView.scrollWheel: mouseCaptured -> surface scroll")
            if window?.firstResponder !== surfaceView {
                window?.makeFirstResponder(surfaceView)
            }
            surfaceView.scrollWheel(with: event)
        } else {
            GhosttyNSView.focusLog("GhosttyScrollView.scrollWheel: super scroll")
            super.scrollWheel(with: event)
        }
    }
}

private final class GhosttyFlashOverlayView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class GhosttySurfaceScrollView: NSView {
    private let backgroundView: NSView
    private let scrollView: GhosttyScrollView
    private let documentView: NSView
    private let surfaceView: GhosttyNSView
    private let flashOverlayView: GhosttyFlashOverlayView
    private let flashLayer: CAShapeLayer
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    private var lastSentRow: Int?
    private var isActive = true
    private var focusWorkItem: DispatchWorkItem?
#if DEBUG
    private static var flashCounts: [UUID: Int] = [:]

    static func flashCount(for surfaceId: UUID) -> Int {
        flashCounts[surfaceId, default: 0]
    }

    static func resetFlashCounts() {
        flashCounts.removeAll()
    }

    private static func recordFlash(for surfaceId: UUID) {
        flashCounts[surfaceId, default: 0] += 1
    }
#endif

    init(surfaceView: GhosttyNSView) {
        self.surfaceView = surfaceView
        backgroundView = NSView(frame: .zero)
        scrollView = GhosttyScrollView()
        flashOverlayView = GhosttyFlashOverlayView(frame: .zero)
        flashLayer = CAShapeLayer()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.clipsToBounds = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.surfaceView = surfaceView

        documentView = NSView(frame: .zero)
        documentView.wantsLayer = true
        documentView.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.documentView = documentView
        documentView.addSubview(surfaceView)

        super.init(frame: .zero)

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor =
            GhosttyApp.shared.defaultBackgroundColor
                .withAlphaComponent(GhosttyApp.shared.defaultBackgroundOpacity)
                .cgColor
        addSubview(backgroundView)
        addSubview(scrollView)
        flashOverlayView.wantsLayer = true
        flashOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        flashOverlayView.layer?.masksToBounds = false
        flashOverlayView.autoresizingMask = [.width, .height]
        flashLayer.fillColor = NSColor.clear.cgColor
        flashLayer.strokeColor = NSColor.systemBlue.cgColor
        flashLayer.lineWidth = 3
        flashLayer.lineJoin = .round
        flashLayer.lineCap = .round
        flashLayer.shadowColor = NSColor.systemBlue.cgColor
        flashLayer.shadowOpacity = 0.6
        flashLayer.shadowRadius = 6
        flashLayer.shadowOffset = .zero
        flashLayer.opacity = 0
        flashOverlayView.layer?.addSublayer(flashLayer)
        addSubview(flashOverlayView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.handleScrollChange()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = true
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.isLiveScrolling = false
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.handleLiveScroll()
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateScrollbar,
            object: surfaceView,
            queue: .main
        ) { [weak self] notification in
            self?.handleScrollbarUpdate(notification)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidUpdateCellSize,
            object: surfaceView,
            queue: .main
        ) { [weak self] _ in
            self?.synchronizeScrollView()
            self?.surfaceView.terminalSurface?.scheduleDelayedResize()
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        cancelFocusRequest()
    }

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    // Avoid stealing focus on scroll; focus is managed explicitly by the surface view.
    override var acceptsFirstResponder: Bool { false }

    override func layout() {
        super.layout()
        backgroundView.frame = bounds
        scrollView.frame = bounds
        surfaceView.frame.size = scrollView.bounds.size
        documentView.frame.size.width = scrollView.bounds.width
        flashOverlayView.frame = bounds
        updateFlashPath()
        synchronizeScrollView()
        synchronizeSurfaceView()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers.removeAll()
        guard let window else { return }
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateFocusForWindow()
            self?.requestFocus()
        })
        windowObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateFocusForWindow()
        })
        updateFocusForWindow()
        if window.isKeyWindow { requestFocus() }
    }

    func attachSurface(_ terminalSurface: TerminalSurface) {
        if surfaceView.terminalSurface === terminalSurface {
            return
        }
        surfaceView.attachSurface(terminalSurface)
    }

    func setResizeSuspended(_ suspended: Bool) {
        surfaceView.setResizeSuspended(suspended)
    }

    func setFocusHandler(_ handler: (() -> Void)?) {
        surfaceView.onFocus = handler
    }

    func setTriggerFlashHandler(_ handler: (() -> Void)?) {
        surfaceView.onTriggerFlash = handler
    }

    func setBackgroundColor(_ color: NSColor) {
        guard let layer = backgroundView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color.cgColor
        CATransaction.commit()
    }

    func triggerFlash() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
#if DEBUG
            if let surfaceId = self.surfaceView.terminalSurface?.id {
                Self.recordFlash(for: surfaceId)
            }
#endif
            self.updateFlashPath()
            self.flashLayer.removeAllAnimations()
            self.flashLayer.opacity = 0
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = [0, 1, 0, 1, 0]
            animation.keyTimes = [0, 0.25, 0.5, 0.75, 1]
            animation.duration = 0.9
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeIn),
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeIn)
            ]
            self.flashLayer.add(animation, forKey: "cmux.flash")
        }
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        updateFocusForWindow()
        if active {
            requestFocus()
        } else {
            cancelFocusRequest()
        }
    }

    func moveFocus(from previous: GhosttySurfaceScrollView? = nil, delay: TimeInterval? = nil) {
        let maxDelay: TimeInterval = 0.5
        guard (delay ?? 0) < maxDelay else { return }

        let nextDelay: TimeInterval = if let delay {
            delay * 2
        } else {
            0.05
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard let window = self.window else {
                self.moveFocus(from: previous, delay: nextDelay)
                return
            }

            if let previous, previous !== self {
                _ = previous.surfaceView.resignFirstResponder()
            }

            window.makeFirstResponder(self.surfaceView)
        }

        let queue = DispatchQueue.main
        if let delay {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    func ensureFocus(for tabId: UUID, surfaceId: UUID, attempt: Int = 0) {
        let maxAttempts = 6
        guard attempt < maxAttempts else { return }
        guard let tabManager = AppDelegate.shared?.tabManager,
              tabManager.selectedTabId == tabId,
              tabManager.focusedSurfaceId(for: tabId) == surfaceId else { return }
        if surfaceView.terminalSurface?.searchState != nil {
            return
        }

        guard let window else {
            scheduleFocusRetry(for: tabId, surfaceId: surfaceId, attempt: attempt)
            return
        }

        guard window.isKeyWindow else {
            scheduleFocusRetry(for: tabId, surfaceId: surfaceId, attempt: attempt)
            return
        }

        if window.firstResponder === surfaceView {
            return
        }

        window.makeFirstResponder(surfaceView)

        if window.firstResponder !== surfaceView {
            scheduleFocusRetry(for: tabId, surfaceId: surfaceId, attempt: attempt)
        }
    }

    private func scheduleFocusRetry(for tabId: UUID, surfaceId: UUID, attempt: Int) {
        let delay = 0.05 * pow(2.0, Double(attempt))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.ensureFocus(for: tabId, surfaceId: surfaceId, attempt: attempt + 1)
        }
    }

    private func updateFocusForWindow() {
        let shouldFocus = isActive && (window?.isKeyWindow ?? false)
        surfaceView.desiredFocus = shouldFocus
        surfaceView.terminalSurface?.setFocus(shouldFocus)
    }

    private func requestFocus(delay: TimeInterval? = nil) {
        guard isActive else { return }
        if surfaceView.terminalSurface?.searchState != nil {
            return
        }
        let maxDelay: TimeInterval = 0.5
        guard (delay ?? 0) < maxDelay else { return }

        let nextDelay: TimeInterval = if let delay {
            delay * 2
        } else {
            0.05
        }

        cancelFocusRequest()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isActive else { return }
            if self.surfaceView.terminalSurface?.searchState != nil {
                return
            }
            guard let window = self.window else {
                self.requestFocus(delay: nextDelay)
                return
            }
            guard window.isKeyWindow else { return }

            if window.firstResponder === self.surfaceView {
                return
            }

            if let responder = window.firstResponder as? NSView, responder !== self.surfaceView {
                _ = responder.resignFirstResponder()
            }

            window.makeFirstResponder(self.surfaceView)

            if window.firstResponder !== self.surfaceView {
                self.requestFocus(delay: nextDelay)
            }
        }

        let queue = DispatchQueue.main
        focusWorkItem = work
        if let delay {
            queue.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    func cancelFocusRequest() {
        focusWorkItem?.cancel()
        focusWorkItem = nil
    }

    private func synchronizeSurfaceView() {
        let visibleRect = scrollView.contentView.documentVisibleRect
        surfaceView.frame.origin = visibleRect.origin
    }

    private func updateFlashPath() {
        let inset: CGFloat = 2
        let radius: CGFloat = 6
        let bounds = flashOverlayView.bounds
        flashLayer.frame = bounds
        guard bounds.width > inset * 2, bounds.height > inset * 2 else {
            flashLayer.path = nil
            return
        }
        let rect = bounds.insetBy(dx: inset, dy: inset)
        flashLayer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func synchronizeScrollView() {
        documentView.frame.size.height = documentHeight()

        if !isLiveScrolling {
            let cellHeight = surfaceView.cellSize.height
            if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
                let offsetY =
                    CGFloat(scrollbar.total - scrollbar.offset - scrollbar.len) * cellHeight
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
                lastSentRow = Int(scrollbar.offset)
            }
        }

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func handleScrollChange() {
        synchronizeSurfaceView()
    }

    private func handleLiveScroll() {
        let cellHeight = surfaceView.cellSize.height
        guard cellHeight > 0 else { return }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = documentView.frame.height
        let scrollOffset = documentHeight - visibleRect.origin.y - visibleRect.height
        let row = Int(scrollOffset / cellHeight)

        guard row != lastSentRow else { return }
        lastSentRow = row
        _ = surfaceView.performBindingAction("scroll_to_row:\(row)")
    }

    private func handleScrollbarUpdate(_ notification: Notification) {
        guard let scrollbar = notification.userInfo?[GhosttyNotificationKey.scrollbar] as? GhosttyScrollbar else {
            return
        }
        surfaceView.scrollbar = scrollbar
        synchronizeScrollView()
    }

    private func documentHeight() -> CGFloat {
        let contentHeight = scrollView.contentSize.height
        let cellHeight = surfaceView.cellSize.height
        if cellHeight > 0, let scrollbar = surfaceView.scrollbar {
            let documentGridHeight = CGFloat(scrollbar.total) * cellHeight
            let padding = contentHeight - (CGFloat(scrollbar.len) * cellHeight)
            return documentGridHeight + padding
        }
        return contentHeight
    }
}

// MARK: - NSTextInputClient

extension GhosttyNSView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break
        }
    }

    func unmarkText() {
        markedText.mutableString.setString("")
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window = self.window else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }
        let viewRect = NSRect(x: 0, y: 0, width: 0, height: 0)
        let winRect = convert(viewRect, to: nil)
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // Get the string value
        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        // Clear marked text since we're inserting
        unmarkText()

        // If we have an accumulator, we're in a keyDown event - accumulate the text
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        // Otherwise send directly to the terminal
        if let surface = surface {
            chars.withCString { ptr in
                var keyEvent = ghostty_input_key_s()
                keyEvent.action = GHOSTTY_ACTION_PRESS
                keyEvent.keycode = 0
                keyEvent.mods = GHOSTTY_MODS_NONE
                keyEvent.consumed_mods = GHOSTTY_MODS_NONE
                keyEvent.text = ptr
                keyEvent.composing = false
                _ = ghostty_surface_key(surface, keyEvent)
            }
        }
    }
}

// MARK: - SwiftUI Wrapper

struct GhosttyTerminalView: NSViewRepresentable {
    let terminalSurface: TerminalSurface
    var isActive: Bool = true
    var isResizing: Bool = false
    var onFocus: ((UUID) -> Void)? = nil
    var onTriggerFlash: (() -> Void)? = nil

    func makeNSView(context: Context) -> GhosttySurfaceScrollView {
        let view = terminalSurface.hostedView
        view.attachSurface(terminalSurface)
        view.setActive(isActive)
        view.setResizeSuspended(isResizing)
        view.setFocusHandler { onFocus?(terminalSurface.id) }
        view.setTriggerFlashHandler(onTriggerFlash)
        return view
    }

    func updateNSView(_ nsView: GhosttySurfaceScrollView, context: Context) {
        nsView.attachSurface(terminalSurface)
        nsView.setActive(isActive)
        nsView.setResizeSuspended(isResizing)
        nsView.setFocusHandler { onFocus?(terminalSurface.id) }
        nsView.setTriggerFlashHandler(onTriggerFlash)
    }
}
