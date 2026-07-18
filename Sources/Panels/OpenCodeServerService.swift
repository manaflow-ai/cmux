import Foundation

private final class OpenCodeServerProcessOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func store(_ process: Process) {
        lock.withLock {
            self.process = process
        }
    }

    func clear(processIdentifier: Int32) {
        lock.withLock {
            guard process?.processIdentifier == processIdentifier else { return }
            process = nil
        }
    }

    func terminate() {
        let process = lock.withLock {
            let process = self.process
            self.process = nil
            return process
        }
        if let process, process.isRunning {
            process.terminate()
        }
    }
}

actor OpenCodeServerService: OpenCodeServerServing {
    private struct PendingConnection {
        let continuation: CheckedContinuation<OpenCodeServerConnection, Error>
    }

    private var process: Process?
    private var connection: OpenCodeServerConnection?
    private var pendingConnections: [PendingConnection] = []
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var outputBuffers: [String: Data] = [:]
    private var leaseCount = 0
    private nonisolated let processOwner = OpenCodeServerProcessOwner()

    func acquireConnection(plan: AgentSessionLaunchPlan) async throws -> OpenCodeServerConnection {
        guard plan.provider == .opencode else {
            throw AgentSessionBridgeError.invalidRequest
        }
        if let connection {
            leaseCount += 1
            return connection
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingConnections.append(PendingConnection(continuation: continuation))
            guard process == nil else { return }
            do {
                try launch(plan: plan)
            } catch {
                failPendingConnections(error)
            }
        }
    }

    func releaseConnection() {
        guard leaseCount > 0 else { return }
        leaseCount -= 1
        guard leaseCount == 0, pendingConnections.isEmpty else { return }
        stopServer()
    }

    nonisolated func terminateImmediately() {
        processOwner.terminate()
    }

    nonisolated static func serverURL(from text: String) -> URL? {
        let marker = "opencode server listening on "
        guard let range = text.range(of: marker) else { return nil }
        let rawURL = text[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init)
        guard let url = rawURL.flatMap(URL.init(string:)),
              agentSessionIsLoopbackURL(url) else {
            return nil
        }
        return url
    }

    private func launch(plan: AgentSessionLaunchPlan) throws {
        let launchEnvironment = plan.environment(overridingWorkingDirectory: nil)
        guard OpenCodeServerAuth(environment: launchEnvironment) != nil else {
            throw AgentSessionBridgeError.providerNotReady(plan.provider.displayName)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.environment = launchEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] process in
            Task {
                await self?.serverExited(
                    processIdentifier: process.processIdentifier,
                    status: process.terminationStatus
                )
            }
        }

        self.process = process
        processOwner.store(process)
        stdoutHandle = stdout.fileHandleForReading
        stderrHandle = stderr.fileHandleForReading
        installReadHandler(stdout.fileHandleForReading, stream: "stdout")
        installReadHandler(stderr.fileHandleForReading, stream: "stderr")

        do {
            try process.run()
        } catch {
            stopServer()
            throw error
        }
    }

    private func installReadHandler(_ fileHandle: FileHandle, stream: String) {
        fileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
            Task {
                await self?.consumeOutputData(data, stream: stream)
            }
        }
    }

    private func consumeOutputData(_ data: Data, stream: String) {
        var buffer = outputBuffers.removeValue(forKey: stream) ?? Data()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            consumeOutputLine(String(decoding: line, as: UTF8.self))
        }
        if data.isEmpty, !buffer.isEmpty {
            consumeOutputLine(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
        }
        if !buffer.isEmpty {
            outputBuffers[stream] = buffer
        }
    }

    private func consumeOutputLine(_ text: String) {
        guard connection == nil,
              let process,
              let baseURL = Self.serverURL(from: text),
              let auth = OpenCodeServerAuth(environment: process.environment ?? [:]) else {
            return
        }
        let connection = OpenCodeServerConnection(
            baseURL: baseURL,
            authorizationHeader: auth.authorizationHeader,
            processIdentifier: process.processIdentifier
        )
        self.connection = connection
        let pending = pendingConnections
        pendingConnections.removeAll(keepingCapacity: false)
        leaseCount += pending.count
        for waiter in pending {
            waiter.continuation.resume(returning: connection)
        }
    }

    private func serverExited(processIdentifier: Int32, status: Int32) {
        guard process?.processIdentifier == processIdentifier else { return }
        let error = AgentSessionBridgeError.providerNotReady(
            "\(AgentSessionProviderID.opencode.displayName) (exit \(status))"
        )
        failPendingConnections(error)
        clearServerState()
    }

    private func failPendingConnections(_ error: Error) {
        let pending = pendingConnections
        pendingConnections.removeAll(keepingCapacity: false)
        for waiter in pending {
            waiter.continuation.resume(throwing: error)
        }
    }

    private func stopServer() {
        if let process, process.isRunning {
            process.terminate()
        }
        clearServerState()
    }

    private func clearServerState() {
        if let process {
            processOwner.clear(processIdentifier: process.processIdentifier)
        }
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        outputBuffers.removeAll(keepingCapacity: false)
        process = nil
        connection = nil
        leaseCount = 0
    }
}
