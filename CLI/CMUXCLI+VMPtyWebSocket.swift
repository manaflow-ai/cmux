import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - VM PTY WebSocket bridge
extension CMUXCLI {
    struct VMPtyWebSocketEndpoint {
        let url: String
        let headers: [String: String]
        let token: String
        let sessionId: String
        let expiresAtUnix: Int64
        let daemon: VMDaemonWebSocketEndpoint?
    }

    struct VMDaemonWebSocketEndpoint {
        let url: String
        let headers: [String: String]
        let token: String
        let sessionId: String
        let expiresAtUnix: Int64
    }

    private struct VMPtyWebSocketConfig: Codable {
        let url: String
        let headers: [String: String]
        let token: String
        let sessionId: String
    }

    private struct TerminalSize {
        let cols: Int
        let rows: Int
    }

    func parseVMPtyWebSocketEndpoint(_ response: [String: Any]) throws -> VMPtyWebSocketEndpoint {
        func parseHeaders(_ value: Any?) -> [String: String] {
            guard let raw = value as? [String: Any] else { return [:] }
            return raw.reduce(into: [String: String]()) { result, pair in
                if let headerValue = pair.value as? String {
                    result[pair.key] = headerValue
                }
            }
        }
        guard let url = response["url"] as? String,
              let token = response["token"] as? String,
              let sessionId = response["session_id"] as? String else {
            throw CLIError(message: """
                cmux could not read the attach information for this Cloud VM.

                What to do:
                  Retry `cmux vm ssh <id>`.
                  If it keeps failing, recreate the VM with `cmux vm new`.

                Details:
                  Cloud VM attach details were incomplete.
                """)
        }
        let headers = parseHeaders(response["headers"])
        let expiresAtUnix = (response["expires_at_unix"] as? Int64)
            ?? Int64((response["expires_at_unix"] as? Double) ?? 0)
        let daemon: VMDaemonWebSocketEndpoint?
        if let daemonResponse = response["daemon"] as? [String: Any],
           let daemonURL = daemonResponse["url"] as? String,
           let daemonToken = daemonResponse["token"] as? String,
           let daemonSessionID = daemonResponse["session_id"] as? String {
            let daemonHeaders = parseHeaders(daemonResponse["headers"])
            let daemonExpiresAtUnix = (daemonResponse["expires_at_unix"] as? Int64)
                ?? Int64((daemonResponse["expires_at_unix"] as? Double) ?? 0)
            daemon = VMDaemonWebSocketEndpoint(
                url: daemonURL,
                headers: daemonHeaders,
                token: daemonToken,
                sessionId: daemonSessionID,
                expiresAtUnix: daemonExpiresAtUnix
            )
        } else {
            daemon = nil
        }
        return VMPtyWebSocketEndpoint(
            url: url,
            headers: headers,
            token: token,
            sessionId: sessionId,
            expiresAtUnix: expiresAtUnix,
            daemon: daemon
        )
    }

    func runVMPtyWebSocketWorkspace(
        id: String,
        endpoint: VMPtyWebSocketEndpoint,
        workspaceName: String?,
        windowRaw: String?,
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat
    ) throws {
        let startedAt = Date()
        let configURL = try writeVMPtyWebSocketConfig(endpoint)
        let executablePath = resolvedExecutableURL()?.path ?? (args.first ?? "cmux")
        let initialStartupCommand = "\(shellQuote(executablePath)) vm-pty-connect --config \(shellQuote(configURL.path)) --id \(shellQuote(id))"
        let splitStartupCommand = "\(shellQuote(executablePath)) vm-pty-attach --id \(shellQuote(id))"
        var params: [String: Any] = [
            "initial_command": initialStartupCommand,
        ]
        if let workspaceName = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspaceName.isEmpty {
            params["title"] = workspaceName
        }
        try applyWindowOrCallerContext(to: &params, client: client, windowRaw: windowRaw)
        let workspaceCreateStartedAt = Date()
        let workspaceCreate = try client.sendV2(method: "workspace.create", params: params)
        guard let workspaceId = workspaceCreate["workspace_id"] as? String, !workspaceId.isEmpty else {
            throw CLIError(message: "workspace.create did not return workspace_id")
        }
        logVMTiming(
            "workspace.create",
            vmID: id,
            transport: "websocket",
            startedAt: workspaceCreateStartedAt,
            extra: "workspace=\(String(workspaceId.prefix(8)))"
        )

        let target = URL(string: endpoint.url)?.host ?? "websocket"
        let configureStartedAt = Date()
        var configureParams: [String: Any] = [
            "workspace_id": workspaceId,
            "destination": target,
            "transport": "websocket",
            "auto_connect": endpoint.daemon != nil,
            "terminal_startup_command": splitStartupCommand,
            "skip_daemon_bootstrap": true,
        ]
        if let daemon = endpoint.daemon {
            configureParams["daemon_websocket_url"] = daemon.url
            configureParams["daemon_websocket_headers"] = daemon.headers
            configureParams["daemon_websocket_token"] = daemon.token
            configureParams["daemon_websocket_session_id"] = daemon.sessionId
            configureParams["daemon_websocket_expires_at_unix"] = daemon.expiresAtUnix
        }
        let configuredPayload: [String: Any]
        do {
            configuredPayload = try client.sendV2(method: "workspace.remote.configure", params: configureParams)
            logVMTiming(
                "workspace.remote.configure",
                vmID: id,
                transport: "websocket",
                startedAt: configureStartedAt,
                extra: "workspace=\(String(workspaceId.prefix(8)))"
            )

            var selectParams: [String: Any] = ["workspace_id": workspaceId]
            if let workspaceWindowId = (workspaceCreate["window_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceWindowId.isEmpty {
                selectParams["window_id"] = workspaceWindowId
            }
            let selectStartedAt = Date()
            _ = try client.sendV2(method: "workspace.select", params: selectParams)
            logVMTiming(
                "workspace.select",
                vmID: id,
                transport: "websocket",
                startedAt: selectStartedAt,
                extra: "workspace=\(String(workspaceId.prefix(8)))"
            )
        } catch {
            do {
                _ = try client.sendV2(method: "workspace.close", params: ["workspace_id": workspaceId])
            } catch {
                let warning = "Warning: failed to rollback workspace \(workspaceId): \(error)\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }
            throw error
        }

        var payload = configuredPayload
        payload["workspace_id"] = workspaceId
        payload["workspace_ref"] = workspaceCreate["workspace_ref"] ?? payload["workspace_ref"] ?? NSNull()
        payload["window_id"] = workspaceCreate["window_id"] ?? payload["window_id"] ?? NSNull()
        payload["window_ref"] = workspaceCreate["window_ref"] ?? payload["window_ref"] ?? NSNull()
        payload["vm_id"] = id
        payload["transport"] = "websocket"
        payload["target"] = target
        payload["expires_at_unix"] = endpoint.expiresAtUnix
        logVMTiming(
            "complete",
            vmID: id,
            transport: "websocket",
            startedAt: startedAt,
            extra: "workspace=\(String(workspaceId.prefix(8)))"
        )

        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            let workspaceHandle = formatHandle(payload, kind: "workspace", idFormat: idFormat) ?? workspaceId
            print("OK workspace=\(workspaceHandle) target=\(target) transport=websocket")
        }
    }

    private func writeVMPtyWebSocketConfig(_ endpoint: VMPtyWebSocketEndpoint) throws -> URL {
        let config = VMPtyWebSocketConfig(
            url: endpoint.url,
            headers: endpoint.headers,
            token: endpoint.token,
            sessionId: endpoint.sessionId
        )
        let data = try JSONEncoder().encode(config)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-vm-pty-\(UUID().uuidString.lowercased()).json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    func runVMPtyConnect(commandArgs: [String]) throws {
        let (configPath, rem0) = parseOption(commandArgs, name: "--config")
        let (vmIDOpt, remaining) = parseOption(rem0, name: "--id")
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw CLIError(message: "vm-pty-connect: unknown flag '\(unknown)'")
        }
        guard let configPath else {
            throw CLIError(message: "Usage: cmux vm-pty-connect --config <path>")
        }
        let configURL = URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: configURL)
        try? FileManager.default.removeItem(at: configURL)
        let config = try JSONDecoder().decode(VMPtyWebSocketConfig.self, from: data)
        let vmID = vmIDOpt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let startedAt = Date()
        let debugEvent: ((String) -> Void)? = {
            guard let vmID, !vmID.isEmpty else { return nil }
            return { [self] stage in
                logVMTiming(stage, vmID: vmID, transport: "websocket", startedAt: startedAt)
            }
        }()
        try VMPtyWebSocketBridge(config: config, debugEvent: debugEvent).run()
    }

    func runVMPtyAttach(commandArgs: [String], client: SocketClient) throws {
        let (vmIDOpt, remaining) = parseOption(commandArgs, name: "--id")
        if let unknown = remaining.first(where: { Self.isFlagToken($0) }) {
            throw CLIError(message: "vm-pty-attach: unknown flag '\(unknown)'. Use `cmux vm-pty-attach --id <vm-id>`.")
        }
        guard remaining.isEmpty else {
            throw CLIError(message: "Usage: cmux vm-pty-attach --id <vm-id>")
        }
        guard let vmID = vmIDOpt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !vmID.isEmpty else {
            throw CLIError(message: "Usage: cmux vm-pty-attach --id <vm-id>")
        }

        let startedAt = Date()
        func log(_ stage: String, extra: String = "") {
            logVMTiming(stage, vmID: vmID, transport: "websocket", startedAt: startedAt, extra: extra)
        }

        let attachInfoStartedAt = Date()
        let response = try client.sendV2(method: "vm.attach_info", params: ["id": vmID], responseTimeout: Self.vmAttachResponseTimeoutSeconds)
        logVMTiming("attach_info", vmID: vmID, transport: "websocket", startedAt: attachInfoStartedAt)
        let endpoint = try parseVMPtyWebSocketEndpoint(response)
        let config = VMPtyWebSocketConfig(
            url: endpoint.url,
            headers: endpoint.headers,
            token: endpoint.token,
            sessionId: endpoint.sessionId
        )
        try VMPtyWebSocketBridge(config: config, debugEvent: { stage in
            log(stage)
        }).run()
    }

    private final class VMPtyWebSocketBridgeDelegate: NSObject, URLSessionWebSocketDelegate {
        private let openSemaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var opened = false
        private var closed = false

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didOpenWithProtocol protocol: String?
        ) {
            lock.lock()
            opened = true
            lock.unlock()
            openSemaphore.signal()
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
            reason: Data?
        ) {
            lock.lock()
            closed = true
            lock.unlock()
            openSemaphore.signal()
        }

        func waitForOpen(timeout: TimeInterval) -> Bool {
            if openSemaphore.wait(timeout: .now() + timeout) != .success {
                return false
            }
            lock.lock()
            defer { lock.unlock() }
            return opened && !closed
        }

        var isClosed: Bool {
            lock.lock()
            defer { lock.unlock() }
            return closed
        }
    }

    private final class VMPtyWebSocketBridge {
        private let config: VMPtyWebSocketConfig
        private let debugEvent: ((String) -> Void)?
        private let sendQueue = DispatchQueue(label: "com.cmux.vm-pty.websocket.send")
        private let stopLock = NSLock()
        private var stopped = false
        private var task: URLSessionWebSocketTask?

        init(config: VMPtyWebSocketConfig, debugEvent: ((String) -> Void)? = nil) {
            self.config = config
            self.debugEvent = debugEvent
        }

        func run() throws {
            guard let url = URL(string: config.url),
                  url.scheme == "wss" || url.scheme == "ws" else {
                throw CLIError(message: "vm-pty-connect: invalid websocket url")
            }
            var request = URLRequest(url: url)
            for (key, value) in config.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let delegate = VMPtyWebSocketBridgeDelegate()
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let task = session.webSocketTask(with: request)
            self.task = task
            defer {
                markStopped()
                task.cancel(with: .normalClosure, reason: nil)
                session.invalidateAndCancel()
            }
            task.resume()
            guard delegate.waitForOpen(timeout: 15) else {
                throw CLIError(message: "vm-pty-connect: timed out opening websocket")
            }
            debugEvent?("websocket.open")

            try sendAuthFrame()
            debugEvent?("websocket.auth")
            try waitForReady(delegate: delegate)
            debugEvent?("websocket.ready")

            let rawMode = TerminalRawMode()
            defer { rawMode?.restore() }
            let resizeSource = startResizeSource()
            defer { resizeSource.cancel() }
            startInputPump()
            try receiveOutputLoop(delegate: delegate)
        }

        private func sendAuthFrame() throws {
            let size = Self.currentTerminalSize()
            let auth: [String: Any] = [
                "type": "auth",
                "token": config.token,
                "session_id": config.sessionId,
                "cols": size.cols,
                "rows": size.rows,
            ]
            let data = try JSONSerialization.data(withJSONObject: auth, options: [])
            let text = String(data: data, encoding: .utf8) ?? "{}"
            try sendSync(.string(text))
        }

        private func waitForReady(delegate: VMPtyWebSocketBridgeDelegate) throws {
            while true {
                guard let message = try receiveSync(delegate: delegate) else {
                    throw CLIError(message: "vm-pty-connect: websocket closed before ready")
                }
                if case .string(let text) = message, text.contains("\"ready\"") {
                    return
                }
            }
        }

        private func startResizeSource() -> DispatchSourceSignal {
            signal(SIGWINCH, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: SIGWINCH,
                queue: DispatchQueue(label: "com.cmux.vm-pty.resize")
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let size = Self.currentTerminalSize()
                let payload: [String: Any] = ["type": "resize", "cols": size.cols, "rows": size.rows]
                guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                      let text = String(data: data, encoding: .utf8) else {
                    return
                }
                self.sendAsync(.string(text))
            }
            source.resume()
            return source
        }

        private static func currentTerminalSize() -> TerminalSize {
            var size = winsize()
            if ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0,
               size.ws_col > 0,
               size.ws_row > 0 {
                return TerminalSize(cols: Int(size.ws_col), rows: Int(size.ws_row))
            }
            return TerminalSize(cols: 80, rows: 24)
        }

        private func startInputPump() {
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                guard let self else { return }
                var buffer = [UInt8](repeating: 0, count: 8192)
                while !self.isStopped {
                    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                    if count > 0 {
                        self.sendAsync(.data(Data(buffer.prefix(count))))
                    } else if count == 0 {
                        self.task?.cancel(with: .normalClosure, reason: nil)
                        return
                    } else if errno != EINTR {
                        self.task?.cancel(with: .goingAway, reason: nil)
                        return
                    }
                }
            }
        }

        private func receiveOutputLoop(delegate: VMPtyWebSocketBridgeDelegate) throws {
            while let message = try receiveSync(delegate: delegate) {
                switch message {
                case .data(let data):
                    FileHandle.standardOutput.write(data)
                case .string:
                    continue
                @unknown default:
                    continue
                }
            }
        }

        private func receiveSync(delegate: VMPtyWebSocketBridgeDelegate) throws -> URLSessionWebSocketTask.Message? {
            guard let task else { throw CLIError(message: "vm-pty-connect: websocket task missing") }
            let semaphore = DispatchSemaphore(value: 0)
            var received: Result<URLSessionWebSocketTask.Message, Error>?
            task.receive { result in
                received = result
                semaphore.signal()
            }
            semaphore.wait()
            switch received {
            case .success(let message):
                return message
            case .failure(let error):
                if delegate.isClosed || isStopped {
                    return nil
                }
                throw error
            case nil:
                return nil
            }
        }

        private func sendAsync(_ message: URLSessionWebSocketTask.Message) {
            sendQueue.async { [weak self] in
                try? self?.sendSync(message)
            }
        }

        private func sendSync(_ message: URLSessionWebSocketTask.Message) throws {
            guard let task else { throw CLIError(message: "vm-pty-connect: websocket task missing") }
            let semaphore = DispatchSemaphore(value: 0)
            var sendError: Error?
            task.send(message) { error in
                sendError = error
                semaphore.signal()
            }
            semaphore.wait()
            if let sendError {
                throw sendError
            }
        }

        private var isStopped: Bool {
            stopLock.lock()
            defer { stopLock.unlock() }
            return stopped
        }

        private func markStopped() {
            stopLock.lock()
            stopped = true
            stopLock.unlock()
        }
    }

    final class TerminalRawMode {
        private var original = termios()
        private var restored = false

        init?() {
            guard tcgetattr(STDIN_FILENO, &original) == 0 else {
                return nil
            }
            var raw = original
            cfmakeraw(&raw)
            guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
                return nil
            }
        }

        deinit {
            restore()
        }

        func restore() {
            guard !restored else { return }
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
            restored = true
        }
    }

}
