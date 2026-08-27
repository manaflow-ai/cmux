import Darwin
internal import Foundation
internal import CmuxCore
internal import CmuxFoundation

// Transport bring-up for the three daemon paths (stdio exec, baked-VM socket
// forward, websocket). Faithful lift; argument composition lives on
// WorkspaceRemoteConfiguration in CmuxCore.
extension RemoteDaemonRPCClient {
    func startViaSSHExec() throws {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        stateQueue.sync {
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
        }

        process.executableURL = URL(fileURLWithPath: transportExecutableOverride ?? "/usr/bin/ssh")
        process.arguments = configuration.daemonTransportArguments(remotePath: remotePath)
        process.environment = configuration.sshProcessEnvironment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.stateQueue.async { [weak self] in
                    self?.consumeStdoutData(data)
                }
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
                self?.stateQueue.async { [weak self] in
                    self?.consumeStdoutData(Data())
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.stateQueue.async { [weak self] in
                    self?.consumeStderrData(data)
                }
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
        process.terminationHandler = { [weak self] terminated in
            self?.stateQueue.async { [weak self] in
                self?.handleProcessTermination(terminated)
            }
        }

        do {
            try process.run()
        } catch {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch SSH daemon transport: \(error.localizedDescription)",
            ])
        }

        stateQueue.sync {
            self.process = process
            self.stdinHandle = stdinPipe.fileHandleForWriting
            self.stdoutHandle = stdoutPipe.fileHandleForReading
            self.stderrHandle = stderrPipe.fileHandleForReading
        }
    }

    func startViaBakedVMSocketForward() throws {
        let localPort = try Self.allocateLoopbackPort()
        let process = Process()
        let stderrPipe = Pipe()

        stateQueue.sync {
            self.stderrPipe = stderrPipe
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = configuration.daemonSocketForwardArguments(
            localPort: localPort,
            remoteSocketPath: Self.bakedVMDaemonSocketPath
        )
        process.environment = configuration.sshProcessEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.stateQueue.async { [weak self] in
                    self?.consumeStderrData(data)
                }
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
        process.terminationHandler = { [weak self] terminated in
            self?.stateQueue.async { [weak self] in
                self?.handleProcessTermination(terminated)
            }
        }

        do {
            try process.run()
        } catch {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 18, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch SSH daemon socket forward: \(error.localizedDescription)",
            ])
        }

        if let startupFailure = Self.startupFailureDetail(
            process: process,
            stderrPipe: stderrPipe,
            gracePeriod: Self.socketForwardStartupGracePeriod
        ) {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 19, userInfo: [
                NSLocalizedDescriptionKey: "Failed to start SSH daemon socket forward: \(startupFailure)",
            ])
        }

        let socketHandle: FileHandle
        do {
            socketHandle = try Self.connectLoopbackSocket(port: localPort)
        } catch {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "Failed to connect VM daemon socket forward: \(error.localizedDescription)",
            ])
        }

        socketHandle.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.stateQueue.async { [weak self] in
                    self?.consumeStdoutData(data)
                }
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
                self?.stateQueue.async { [weak self] in
                    self?.consumeStdoutData(Data())
                }
            }
        }

        stateQueue.sync {
            self.process = process
            self.stdinHandle = socketHandle
            self.stdoutHandle = socketHandle
            self.stderrHandle = stderrPipe.fileHandleForReading
        }
    }

    func startViaWebSocket() throws {
        guard let endpoint = configuration.daemonWebSocketEndpoint else {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "websocket daemon endpoint is missing",
            ])
        }
        guard let url = URL(string: endpoint.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "wss" || scheme == "ws" else {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 24, userInfo: [
                NSLocalizedDescriptionKey: "invalid websocket daemon URL \(endpoint.url)",
            ])
        }

        var request = URLRequest(url: url)
        for (key, value) in endpoint.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let delegate = RemoteDaemonWebSocketDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.resume()
        guard delegate.waitForOpen(timeout: 15.0) else {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 25, userInfo: [
                NSLocalizedDescriptionKey: "timed out opening daemon websocket",
            ])
        }

        stateQueue.sync {
            self.webSocketSession = session
            self.webSocketTask = task
            self.webSocketDelegate = delegate
            self.markTransportOpenLocked()
            self.startWebSocketKeepaliveLocked()
        }

        stateQueue.async {
            self.receiveNextWebSocketMessageLocked()
        }

        let authPayload: [String: Any] = [
            "type": "auth",
            "token": endpoint.token,
            "session_id": endpoint.sessionId,
        ]
        let authData = try Self.encodeJSON(authPayload)
        do {
            try writeQueue.sync {
                try writePayload(authData)
            }
        } catch {
            stop(suppressTerminationCallback: true)
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 26, userInfo: [
                NSLocalizedDescriptionKey: "failed authenticating daemon websocket: \(error.localizedDescription)",
            ])
        }
    }

    static func usesSocketForwardTransport(configuration: WorkspaceRemoteConfiguration) -> Bool {
        configuration.transport == .ssh && configuration.skipDaemonBootstrap && configuration.daemonWebSocketEndpoint == nil
    }

    static func allocateLoopbackPort() throws -> Int {
        for _ in 0..<8 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { break }
            defer { close(fd) }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(0)
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bindResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { continue }

            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    getsockname(fd, sockaddrPtr, &len)
                }
            }
            guard nameResult == 0 else { continue }

            let port = Int(UInt16(bigEndian: bound.sin_port))
            if port > 0 {
                return port
            }
        }

        throw NSError(domain: "cmux.remote.daemon.rpc", code: 21, userInfo: [
            NSLocalizedDescriptionKey: "failed to allocate local daemon socket forward port",
        ])
    }

    static func connectLoopbackSocket(port: Int) throws -> FileHandle {
        guard port > 0 && port <= 65535 else {
            throw NSError(domain: "cmux.remote.daemon.rpc", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "invalid local daemon socket forward port \(port)",
            ])
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(errno)),
            ])
        }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            let errorCode = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode), userInfo: [
                NSLocalizedDescriptionKey: String(cString: strerror(errorCode)),
            ])
        }

        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func startupFailureDetail(
        process: Process,
        stderrPipe: Pipe,
        gracePeriod: TimeInterval
    ) -> String? {
        if process.isRunning {
            let originalTerminationHandler = process.terminationHandler
            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { terminated in
                originalTerminationHandler?(terminated)
                exitSemaphore.signal()
            }
            if !process.isRunning {
                exitSemaphore.signal()
            }
            guard exitSemaphore.wait(timeout: .now() + max(0, gracePeriod)) == .success else {
                return nil
            }
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return bestErrorLine(stderr: stderr) ?? "status=\(process.terminationStatus)"
    }

    static func bestErrorLine(stderr: String) -> String? {
        let lines = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }
}
