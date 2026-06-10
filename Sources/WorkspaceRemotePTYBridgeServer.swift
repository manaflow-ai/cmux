import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


final class WorkspaceRemotePTYBridgeServer {
    private static let unusedBridgeTimeout: TimeInterval = 30.0

    struct Endpoint {
        let host: String
        let port: Int
        let token: String
        let sessionID: String
        let attachmentID: String
    }

    private final class Session {
        private static let maxHandshakeBytes = 4096
        private static let handshakeTimeout: TimeInterval = 30.0
        private static let maxPendingOutputSends = 256
        private static let maxPendingOutputBytes = 4 * 1024 * 1024
        private static let maxPendingInputWrites = 256
        private static let maxPendingInputBytes = 4 * 1024 * 1024

        private let connection: NWConnection
        private let rpcClient: any WorkspaceRemotePTYBridgeRPCClient
        private let sessionID: String
        private let attachmentID: String
        private let command: String?
        private let requireExisting: Bool
        private let token: String
        private let queue: DispatchQueue
        private let rpcQueue = DispatchQueue(label: "com.cmux.remote-ssh.pty-bridge.rpc.\(UUID().uuidString)", qos: .userInitiated)
        private let onClose: () -> Void

        private var isClosed = false
        private var isAttaching = false
        private var isAttached = false
        private var handshakeBuffer = Data()
        private var pendingInputBeforeAttach = Data()
        private var pendingInputWrites = 0
        private var pendingInputBytes = 0
        private var pendingOutputSends = 0
        private var pendingOutputBytes = 0
        private var clientInputDidComplete = false
        private var pendingPTYEventsBeforeReady: [WorkspaceRemotePTYBridgeEvent] = []
        private var pendingPTYEventBytesBeforeReady = 0
        private var closeWhenOutputFlushes: (detach: Bool, gracefulOutputClose: Bool)?
        private var handshakeTimeoutWorkItem: DispatchWorkItem?
        private var remoteAttachment: WorkspaceRemotePTYBridgeAttachment?
        private var clientPID: pid_t?
        private var clientProcessExitSource: DispatchSourceProcess?

        init(
            connection: NWConnection,
            rpcClient: any WorkspaceRemotePTYBridgeRPCClient,
            sessionID: String,
            attachmentID: String,
            command: String?,
            requireExisting: Bool,
            token: String,
            queue: DispatchQueue,
            onClose: @escaping () -> Void
        ) {
            self.connection = connection
            self.rpcClient = rpcClient
            self.sessionID = sessionID
            self.attachmentID = attachmentID
            self.command = command
            self.requireExisting = requireExisting
            self.token = token
            self.queue = queue
            self.onClose = onClose
        }

        func start() {
            armHandshakeTimeout()
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed, .cancelled:
                    self.close(detach: true)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            receiveNext()
        }

        func stop() {
            close(detach: true)
        }

        private func receiveNext() {
            guard !isClosed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, isComplete, error in
                guard let self, !self.isClosed else { return }
                if let data, !data.isEmpty {
                    if self.isAttached {
                        self.forwardInput(data)
                    } else if self.isAttaching {
                        self.bufferInputUntilAttach(data)
                    } else {
                        self.consumeHandshake(data)
                    }
                }
                if isComplete {
                    // TCP half-close means the CLI is done sending stdin, but still
                    // expects PTY output until the remote session exits.
                    self.clientInputDidComplete = true
                    if self.isAttaching {
                        return
                    }
                    if !self.isAttached {
                        self.close(detach: false)
                    } else if self.clientHasExited() {
                        self.close(detach: true)
                    }
                    return
                }
                if error != nil {
                    self.close(detach: true)
                    return
                }
                self.receiveNext()
            }
        }

        private func consumeHandshake(_ data: Data) {
            handshakeBuffer.append(data)
            guard handshakeBuffer.count <= Self.maxHandshakeBytes else {
                close(detach: false)
                return
            }
            guard let newlineIndex = handshakeBuffer.firstIndex(of: 0x0A) else { return }
            var lineData = Data(handshakeBuffer[..<newlineIndex])
            let remainingStart = handshakeBuffer.index(after: newlineIndex)
            let remaining = remainingStart < handshakeBuffer.endIndex
                ? Data(handshakeBuffer[remainingStart...])
                : Data()
            handshakeBuffer.removeAll(keepingCapacity: false)
            if let carriageIndex = lineData.lastIndex(of: 0x0D),
               carriageIndex == lineData.index(before: lineData.endIndex) {
                lineData.remove(at: carriageIndex)
            }
            guard let payload = try? JSONSerialization.jsonObject(with: lineData, options: []) as? [String: Any],
                  let receivedToken = payload["token"] as? String,
                  receivedToken == token else {
                close(detach: false)
                return
            }
            let cols = Self.strictInt(payload["cols"]) ?? 80
            let rows = Self.strictInt(payload["rows"]) ?? 24
            clientPID = Self.strictPositivePID(payload["client_pid"])
            armClientProcessExitMonitor()
            handshakeTimeoutWorkItem?.cancel()
            handshakeTimeoutWorkItem = nil
            isAttaching = true
            if !remaining.isEmpty {
                bufferInputUntilAttach(remaining)
            }
            rpcQueue.async { [weak self] in
                guard let self else { return }
                let result: Result<WorkspaceRemotePTYBridgeAttachment, Error>
                do {
                    let remoteAttachment = try self.rpcClient.attachBridgePTY(
                        sessionID: self.sessionID,
                        attachmentID: self.attachmentID,
                        cols: cols,
                        rows: rows,
                        command: self.command,
                        requireExisting: self.requireExisting,
                        queue: self.queue
                    ) { [weak self] event in
                        self?.handlePTYEvent(event)
                    }
                    result = .success(remoteAttachment)
                } catch {
                    result = .failure(error)
                }
                self.queue.async {
                    self.finishAttach(result)
                }
            }
        }

        private func finishAttach(_ result: Result<WorkspaceRemotePTYBridgeAttachment, Error>) {
            guard !isClosed else {
                if case .success(let remoteAttachment) = result {
                    detachRemoteAttachment(remoteAttachment)
                }
                return
            }
            isAttaching = false
            do {
                let remoteAttachment = try result.get()
                self.remoteAttachment = remoteAttachment
                sendBridgeStatus([
                    "type": "ready",
                    "attachment_token": remoteAttachment.token,
                ])
                isAttached = true
                let pendingPTYEvents = pendingPTYEventsBeforeReady
                pendingPTYEventsBeforeReady.removeAll(keepingCapacity: false)
                pendingPTYEventBytesBeforeReady = 0
                for event in pendingPTYEvents {
                    handleAttachedPTYEvent(event)
                    if isClosed { return }
                }
                if !pendingInputBeforeAttach.isEmpty {
                    let pendingInput = pendingInputBeforeAttach
                    pendingInputBeforeAttach.removeAll(keepingCapacity: false)
                    forwardInput(pendingInput)
                }
                if clientInputDidComplete, clientHasExited() {
                    close(detach: true)
                }
            } catch {
                closeWithBridgeError(Self.userFacingBridgeErrorMessage(error))
            }
        }

        private func armHandshakeTimeout() {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, !self.isClosed, !self.isAttached else { return }
                self.close(detach: false)
            }
            handshakeTimeoutWorkItem = workItem
            queue.asyncAfter(deadline: .now() + Self.handshakeTimeout, execute: workItem)
        }

        private func bufferInputUntilAttach(_ data: Data) {
            guard !data.isEmpty else { return }
            guard pendingInputBeforeAttach.count <= Self.maxPendingInputBytes - data.count else {
                close(detach: false)
                return
            }
            pendingInputBeforeAttach.append(data)
        }

        private func forwardInput(_ data: Data) {
            guard !data.isEmpty else { return }
            guard let remoteAttachment else {
                close(detach: true)
                return
            }
            guard pendingInputWrites < Self.maxPendingInputWrites,
                  pendingInputBytes <= Self.maxPendingInputBytes - data.count else {
                close(detach: true)
                return
            }
            pendingInputWrites += 1
            pendingInputBytes += data.count
            let currentSessionID = sessionID
            rpcQueue.async { [weak self, data, remoteAttachment] in
                guard let self else { return }
                let shouldWrite = self.queue.sync { !self.isClosed }
                guard shouldWrite else {
                    self.queue.async {
                        self.handleInputWriteFinished(bytes: data.count, error: nil)
                    }
                    return
                }
                self.rpcClient.writePTY(
                    sessionID: currentSessionID,
                    attachmentID: remoteAttachment.attachmentID,
                    attachmentToken: remoteAttachment.token,
                    data: data
                ) { [weak self] writeError in
                    self?.queue.async {
                        self?.handleInputWriteFinished(bytes: data.count, error: writeError)
                    }
                }
            }
        }

        private func handleInputWriteFinished(bytes: Int, error: Error?) {
            pendingInputWrites = max(0, pendingInputWrites - 1)
            pendingInputBytes = max(0, pendingInputBytes - bytes)
            if error != nil {
                close(detach: true)
            }
        }

        private func detachRemoteAttachment(_ attachment: WorkspaceRemotePTYBridgeAttachment) {
            rpcQueue.async { [rpcClient, sessionID] in
                rpcClient.detachPTY(
                    sessionID: sessionID,
                    attachmentID: attachment.attachmentID,
                    attachmentToken: attachment.token
                )
            }
        }

        private func handlePTYEvent(_ event: WorkspaceRemotePTYBridgeEvent) {
            guard !isClosed else { return }
            guard !isAttaching else {
                bufferPTYEventUntilReady(event)
                return
            }
            handleAttachedPTYEvent(event)
        }

        private func bufferPTYEventUntilReady(_ event: WorkspaceRemotePTYBridgeEvent) {
            switch event {
            case .ready:
                return
            case .data(let data):
                guard !data.isEmpty else { return }
                guard pendingPTYEventsBeforeReady.count < Self.maxPendingOutputSends,
                      pendingPTYEventBytesBeforeReady <= Self.maxPendingOutputBytes - data.count else {
                    close(detach: true)
                    return
                }
                pendingPTYEventBytesBeforeReady += data.count
                pendingPTYEventsBeforeReady.append(event)
            case .exit, .error:
                guard pendingPTYEventsBeforeReady.count < Self.maxPendingOutputSends else {
                    close(detach: true)
                    return
                }
                pendingPTYEventsBeforeReady.append(event)
            }
        }

        private func handleAttachedPTYEvent(_ event: WorkspaceRemotePTYBridgeEvent) {
            guard !isClosed else { return }
            switch event {
            case .ready:
                return
            case .data(let data):
                guard !data.isEmpty else { return }
                sendBufferedOutput(data, detachOnOverflow: true)
            case .exit, .error:
                closeAfterOutputFlush(detach: false, gracefulOutputClose: true)
            }
        }

        private func sendBufferedOutput(_ data: Data, detachOnOverflow: Bool) {
            guard !isClosed, !data.isEmpty else { return }
            guard pendingOutputSends < Self.maxPendingOutputSends,
                  pendingOutputBytes <= Self.maxPendingOutputBytes - data.count else {
                close(detach: detachOnOverflow)
                return
            }

            pendingOutputSends += 1
            pendingOutputBytes += data.count
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                self?.queue.async {
                    self?.handleOutputSendFinished(bytes: data.count, error: error)
                }
            })
        }

        private func handleOutputSendFinished(bytes: Int, error: NWError?) {
            guard !isClosed else { return }
            pendingOutputSends = max(0, pendingOutputSends - 1)
            pendingOutputBytes = max(0, pendingOutputBytes - bytes)
            if error != nil {
                close(detach: true)
                return
            }
            if let pendingClose = closeWhenOutputFlushes, pendingOutputSends == 0 {
                close(
                    detach: pendingClose.detach,
                    gracefulOutputClose: pendingClose.gracefulOutputClose
                )
            }
        }

        private func closeAfterOutputFlush(detach: Bool, gracefulOutputClose: Bool = false) {
            guard !isClosed else { return }
            if pendingOutputSends == 0 {
                close(detach: detach, gracefulOutputClose: gracefulOutputClose)
                return
            }
            closeWhenOutputFlushes = (detach: detach, gracefulOutputClose: gracefulOutputClose)
        }

        private func sendBridgeStatus(_ payload: [String: Any]) {
            guard !isClosed,
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                return
            }
            var line = data
            line.append(0x0A)
            sendBufferedOutput(line, detachOnOverflow: false)
        }

        private func closeWithBridgeError(_ message: String) {
            guard !isClosed else { return }
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = trimmed.isEmpty ? "remote PTY attach failed" : trimmed
            let payload: [String: Any] = ["type": "error", "message": detail]
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
                close(detach: false)
                return
            }
            var line = data
            line.append(0x0A)
            isClosed = true
            connection.send(content: line, completion: .contentProcessed { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.connection.cancel()
                    self.onClose()
                }
            })
        }

        private func close(detach: Bool, gracefulOutputClose: Bool = false) {
            guard !isClosed else { return }
            isClosed = true
            handshakeTimeoutWorkItem?.cancel()
            handshakeTimeoutWorkItem = nil
            isAttaching = false
            pendingInputBeforeAttach.removeAll(keepingCapacity: false)
            pendingPTYEventsBeforeReady.removeAll(keepingCapacity: false)
            pendingPTYEventBytesBeforeReady = 0
            clientProcessExitSource?.cancel()
            clientProcessExitSource = nil
            if detach && isAttached, let remoteAttachment {
                detachRemoteAttachment(remoteAttachment)
            }
            if gracefulOutputClose && !detach {
                connection.send(
                    content: nil,
                    contentContext: .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] _ in
                        guard let self else { return }
                        self.queue.async {
                            self.connection.cancel()
                            self.onClose()
                        }
                    }
                )
                return
            }
            connection.cancel()
            onClose()
        }

        private static func strictInt(_ value: Any?) -> Int? {
            if let int = value as? Int { return int }
            if let number = value as? NSNumber {
                let double = number.doubleValue
                guard double.rounded(.towardZero) == double else { return nil }
                return number.intValue
            }
            return nil
        }

        private static func strictPositivePID(_ value: Any?) -> pid_t? {
            guard let intValue = strictInt(value),
                  intValue > 0,
                  intValue <= Int(Int32.max) else {
                return nil
            }
            return pid_t(intValue)
        }

        private func armClientProcessExitMonitor() {
            clientProcessExitSource?.cancel()
            clientProcessExitSource = nil
            guard let clientPID, Self.processIsRunning(clientPID) else { return }
            let source = DispatchSource.makeProcessSource(identifier: clientPID, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in
                self?.close(detach: true)
            }
            clientProcessExitSource = source
            source.resume()
        }

        private func clientHasExited() -> Bool {
            guard let clientPID else { return false }
            return !Self.processIsRunning(clientPID)
        }

        private static func processIsRunning(_ pid: pid_t) -> Bool {
            guard pid > 0 else { return false }
            if Darwin.kill(pid, 0) == 0 { return true }
            return errno == EPERM
        }

        private static func userFacingBridgeErrorMessage(_ error: Error) -> String {
            let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = message.lowercased()
            if lowered.contains("missing required capability") ||
                lowered.contains("pty.session") ||
                lowered.contains(WorkspaceRemoteDaemonRPCClient.requiredPTYWriteNotificationCapability) {
                return String(
                    localized: "remoteDaemon.error.missingPersistentPTYCapability",
                    defaultValue: "remote daemon does not support persistent SSH PTY sessions; reconnect the remote workspace to update cmux"
                )
            }
            if lowered.contains("pty_session_not_found") ||
                (lowered.contains("persistent ssh pty session") && lowered.contains("not running")) ||
                (lowered.contains("persistent pty session") && lowered.contains("not running")) {
                return String(
                    localized: "remotePTYAttach.error.sessionEnded",
                    defaultValue: "persistent SSH PTY session is no longer running"
                )
            }
            if lowered.contains("pty_input_queue_full") || lowered.contains("pty input queue is full") {
                return String(
                    localized: "remotePTYAttach.error.inputBackedUp",
                    defaultValue: "remote PTY input is temporarily backed up"
                )
            }
            if lowered.contains("timed out") || lowered.contains("timeout") {
                return String(
                    localized: "remotePTYAttach.error.daemonTimeout",
                    defaultValue: "remote daemon did not respond in time"
                )
            }
            // Surface the daemon's PTY-allocation diagnostic (it names the failing
            // device and the devpts/ptmxmode cause) instead of collapsing it into a
            // generic message. Key off the daemon's stable marker only, so an
            // unrelated error that merely mentions a device path is not leaked, and
            // route the dynamic detail through the localization API to match the
            // surrounding branches. See issue #5185.
            if lowered.contains("could not allocate a remote pty") {
                return String(
                    localized: "remotePTYAttach.error.allocationDiagnostic",
                    defaultValue: "\(message)"
                )
            }
            return String(
                localized: "remotePTYAttach.error.attachFailed",
                defaultValue: "remote PTY attach failed"
            )
        }
    }

    private let rpcClient: any WorkspaceRemotePTYBridgeRPCClient
    private let sessionID: String
    private let attachmentID: String
    private let command: String?
    private let requireExisting: Bool
    private let token = UUID().uuidString.lowercased()
    private let queue = DispatchQueue(label: "com.cmux.remote-ssh.pty-bridge.\(UUID().uuidString)", qos: .userInitiated)
    private let onStop: () -> Void

    private var listener: NWListener?
    private var session: Session?
    private var isStopped = false
    private var unusedBridgeTimeoutWorkItem: DispatchWorkItem?

    init(
        rpcClient: any WorkspaceRemotePTYBridgeRPCClient,
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool,
        onStop: @escaping () -> Void
    ) {
        self.rpcClient = rpcClient
        self.sessionID = sessionID
        self.attachmentID = attachmentID
        self.command = command
        self.requireExisting = requireExisting
        self.onStop = onStop
    }

    func start() throws -> Endpoint {
        let listener = try Self.makeLoopbackListener()
        let readySemaphore = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var capturedError: Error?
        var boundPort: Int?

        listener.newConnectionHandler = { [weak self] connection in
            self?.queue.async {
                self?.acceptConnectionLocked(connection)
            }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                stateLock.lock()
                boundPort = listener.port.map { Int($0.rawValue) }
                stateLock.unlock()
                readySemaphore.signal()
            case .failed(let error):
                stateLock.lock()
                capturedError = error
                stateLock.unlock()
                readySemaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        guard readySemaphore.wait(timeout: .now() + 5.0) == .success else {
            listener.cancel()
            throw NSError(domain: "cmux.remote.pty", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "timed out waiting for PTY bridge listener",
            ])
        }
        stateLock.lock()
        let startupError = capturedError
        let startupPort = boundPort
        stateLock.unlock()
        if let startupError {
            listener.cancel()
            throw startupError
        }
        guard let startupPort, startupPort > 0 else {
            listener.cancel()
            throw NSError(domain: "cmux.remote.pty", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "failed to bind PTY bridge listener",
            ])
        }

        self.listener = listener
        queue.async { [weak self] in
            self?.armUnusedBridgeTimeoutLocked()
        }
        return Endpoint(
            host: "127.0.0.1",
            port: startupPort,
            token: token,
            sessionID: sessionID,
            attachmentID: attachmentID
        )
    }

    func stop() {
        queue.async {
            self.stopLocked()
        }
    }

    private func acceptConnectionLocked(_ connection: NWConnection) {
        guard !isStopped, session == nil else {
            connection.cancel()
            return
        }
        unusedBridgeTimeoutWorkItem?.cancel()
        unusedBridgeTimeoutWorkItem = nil
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil

        let session = Session(
            connection: connection,
            rpcClient: rpcClient,
            sessionID: sessionID,
            attachmentID: attachmentID,
            command: command,
            requireExisting: requireExisting,
            token: token,
            queue: queue
        ) { [weak self] in
            self?.stopLocked()
        }
        self.session = session
        session.start()
    }

    private func armUnusedBridgeTimeoutLocked() {
        guard !isStopped, listener != nil, session == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.stopLocked()
        }
        unusedBridgeTimeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + Self.unusedBridgeTimeout, execute: workItem)
    }

    private func stopLocked() {
        guard !isStopped else { return }
        isStopped = true
        unusedBridgeTimeoutWorkItem?.cancel()
        unusedBridgeTimeoutWorkItem = nil
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        let activeSession = session
        session = nil
        activeSession?.stop()
        onStop()
    }

    private static func makeLoopbackListener() throws -> NWListener {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        return try NWListener(using: parameters)
    }
}

