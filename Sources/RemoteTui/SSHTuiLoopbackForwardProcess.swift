import CmuxCloud
import Foundation
import Darwin

/// Owns one `cmux-tui remote forward` process and its loopback listener.
actor SSHTuiLoopbackForwardProcess {
    private var process: Process?
    private var exit: CloudLinkFirstValue<Int32>?
    private var localPort: UInt16?
    private var stopped = false

    var readyPort: UInt16? { process?.isRunning == true && !stopped ? localPort : nil }

    func start(client: URL, arguments: [String], environment: [String: String]?, listener: SSHTuiLoopbackListenerLease) async throws -> UInt16 {
        guard !stopped else { throw CancellationError() }
        // Duplicate the descriptor before changing the listener's rejection
        // state. A failed duplication must leave the existing 503 handler in
        // place; otherwise this lease would silently stop rejecting requests.
        let childInput = try listener.makeChildInput()
        let listenerGeneration = listener.prepareForChild()
        let child = Process()
        let output = Pipe()
        let errors = Pipe()
        let ended = CloudLinkFirstValue<Int32>()
        let ready = CloudLinkFirstValue<UInt16>()
        child.executableURL = client
        child.arguments = arguments
        child.environment = CloudBrowserProxyProcess.sanitizedEnvironment(environment ?? ProcessInfo.processInfo.environment)
        child.standardInput = childInput
        child.standardOutput = output
        child.standardError = errors
        child.terminationHandler = { terminated in
            listener.childDidStop(generation: listenerGeneration)
            ended.resolve(terminated.terminationStatus)
            ready.resolve(nil)
        }
        do {
            try child.run()
        } catch {
            listener.childDidStop(generation: listenerGeneration)
            throw error
        }
        process = child
        exit = ended

        let lines = CloudLinkPipe.lines(from: output.fileHandleForReading)
        Task {
            for await line in lines {
                guard let url = URLComponents(string: line),
                      url.scheme == "http",
                      ["127.0.0.1", "::1"].contains(url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() ?? ""),
                      let port = url.port, port > 0, port <= Int(UInt16.max) else { continue }
                ready.resolve(UInt16(port))
            }
            ready.resolve(nil)
        }
        // Always drain stderr so a reconnecting SSH process cannot block.
        let errorLines = CloudLinkPipe.lines(from: errors.fileHandleForReading)
        Task { for await _ in errorLines {} }

        do {
            let port = try await withThrowingTaskGroup(of: UInt16?.self) { group in
                group.addTask { await ready.result }
                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    throw CloudMachineLink.LinkError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            try Task.checkCancellation()
            guard !stopped, child.isRunning, let port else {
                throw CloudMachineLink.LinkError.spawnFailed(String(
                    localized: "ssh.tui.browserListener.forwardEnded",
                    defaultValue: "The SSH port forward ended before it became ready."
                ))
            }
            guard port == listener.port else {
                throw CloudMachineLink.LinkError.spawnFailed(String(
                    localized: "ssh.tui.browserListener.portMismatch",
                    defaultValue: "The SSH helper reported a different browser listener port."
                ))
            }
            localPort = port
            return port
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        localPort = nil
        if let process, let exit {
            let finished = Task.detached { await exit.result }
            if process.isRunning { process.terminate() }
            let forceStop = Task.detached {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            _ = await finished.value
            forceStop.cancel()
        }
        process = nil
        exit = nil
    }
}
