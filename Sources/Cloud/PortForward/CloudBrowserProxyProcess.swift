import Foundation
import Darwin
import os

nonisolated private let browserProxyLog = Logger(subsystem: "com.cmuxterm.app", category: "CloudBrowserProxy")

/// Owns one VM's browser carrier and its WireGuard claim until shutdown or child exit.
actor CloudBrowserProxyProcess {
    private static let secretEnvironmentKeys: Set<String> = [
        "CMUX_AUTH_CREDENTIALS_FILE",
        "CMUX_DOGFOOD_STACK_EMAIL",
        "CMUX_DOGFOOD_STACK_PASSWORD",
        "CMUX_UITEST_STACK_EMAIL",
        "CMUX_UITEST_STACK_PASSWORD",
        "CMUX_SOCKET_PASSWORD",
    ]

    private var process: Process?
    private var exit: CloudLinkFirstValue<Int32>?
    private var releaseHub: (@Sendable () async -> Void)?
    private var endpoint: CloudBrowserProxyEndpoint?
    private var stopped = false
    let addresses: [String]

    init(addresses: [String]) { self.addresses = addresses }

    /// The browser carrier authenticates with its generated CONNECT credential
    /// and its explicit state directory. It must not inherit app login material
    /// or dogfood passwords from the GUI process environment.
    nonisolated static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { !secretEnvironmentKeys.contains($0.key) }
    }

    var readyEndpoint: CloudBrowserProxyEndpoint? {
        process?.isRunning == true && !stopped ? endpoint : nil
    }

    func start(client: URL, arguments: [String], releaseHub: @escaping @Sendable () async -> Void) async throws -> CloudBrowserProxyEndpoint {
        guard !stopped else {
            await releaseHub()
            throw CancellationError()
        }
        self.releaseHub = releaseHub
        let child = Process()
        let output = Pipe()
        let errors = Pipe()
        let ended = CloudLinkFirstValue<Int32>()
        let ready = CloudLinkFirstValue<CloudBrowserProxyEndpoint>()
        child.executableURL = client
        child.arguments = arguments
        child.environment = Self.sanitizedEnvironment(ProcessInfo.processInfo.environment)
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = errors
        child.terminationHandler = { terminated in
            ended.resolve(terminated.terminationStatus)
            ready.resolve(nil)
        }
        do { try child.run() } catch {
            await releaseClaim()
            throw error
        }
        process = child
        exit = ended
        let lines = CloudLinkPipe.lines(from: output.fileHandleForReading)
        Task {
            for await line in lines {
                // The readiness record contains a credential. Never log stdout, including failures.
                if let data = line.data(using: .utf8),
                   let record = try? JSONDecoder().decode(CloudBrowserProxyEndpoint.self, from: data),
                   record.host == "127.0.0.1", record.port != 0,
                   !record.username.isEmpty, !record.password.isEmpty {
                    ready.resolve(record)
                }
            }
            ready.resolve(nil)
        }
        // Drain stderr concurrently so a reconnecting child cannot block on its pipe.
        let errorLines = CloudLinkPipe.lines(from: errors.fileHandleForReading)
        Task {
            for await line in errorLines {
                browserProxyLog.debug("browser carrier: \(line, privacy: .private)")
            }
        }
        Task { [weak self] in
            _ = await ended.result
            await self?.didExit()
        }
        do {
            let value = try await withThrowingTaskGroup(of: CloudBrowserProxyEndpoint?.self) { group in
                group.addTask { await ready.result }
                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    throw CloudMachineLink.LinkError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
            try Task.checkCancellation()
            guard !stopped, child.isRunning, let value else {
                throw CloudMachineLink.LinkError.spawnFailed(String(localized: "cloud.browser.connectionEnded", defaultValue: "The Cloud connection ended. Reload to reconnect."))
            }
            endpoint = value
            return value
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        stopped = true
        endpoint = nil
        if let process, let exit {
            // Retain Process until the termination callback has fired, even when our caller cancels.
            let finished = Task.detached { await exit.result }
            if process.isRunning { process.terminate() }
            let forceStop = Task.detached {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                // Process remains retained until its real exit, so this PID cannot be reused here.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            _ = await finished.value
            forceStop.cancel()
        }
        process = nil
        exit = nil
        await releaseClaim()
    }

    private func didExit() async {
        endpoint = nil
        await releaseClaim()
    }

    private func releaseClaim() async {
        let release = releaseHub
        releaseHub = nil
        await release?()
    }
}
