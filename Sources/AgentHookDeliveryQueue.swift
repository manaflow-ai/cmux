import Foundation

/// Owns lifecycle-hook ordering and bounds downstream delivery to one process.
final class AgentHookDeliveryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [AgentHookDeliveryEvent] = []
    private var nextPendingIndex = 0
    private var isDraining = false
    private let workerQueue = DispatchQueue(
        label: "com.cmuxterm.agent-hook-delivery",
        qos: .utility
    )
    private let executableURLProvider: @Sendable () -> URL?

    init(executableURLProvider: @escaping @Sendable () -> URL? = {
        Bundle.main.resourceURL?.appendingPathComponent("bin/cmux", isDirectory: false)
    }) {
        self.executableURLProvider = executableURLProvider
    }

    /// Appends before the socket acknowledges the event. The caller performs
    /// no downstream work, so acceptance remains constant-time.
    func enqueue(_ event: AgentHookDeliveryEvent) {
        lock.lock()
        pending.append(event)
        let shouldStartDraining = !isDraining
        if shouldStartDraining {
            isDraining = true
        }
        lock.unlock()

        guard shouldStartDraining else { return }
        workerQueue.async { [self] in
            drain()
        }
    }

    private func drain() {
        while let event = takeNextEvent() {
            guard let executableURL = executableURLProvider() else { continue }
            deliver(event, executableURL: executableURL)
        }
    }

    private func takeNextEvent() -> AgentHookDeliveryEvent? {
        lock.lock()
        defer { lock.unlock() }
        guard nextPendingIndex < pending.count else {
            pending.removeAll(keepingCapacity: true)
            nextPendingIndex = 0
            isDraining = false
            return nil
        }
        let event = pending[nextPendingIndex]
        nextPendingIndex += 1
        return event
    }

    /// The serial worker admits only one delivery process at a time, so hook
    /// bursts cannot create a process or thread storm.
    private func deliver(_ event: AgentHookDeliveryEvent, executableURL: URL) {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--socket", event.socketPath,
            "hooks", event.agent, event.subcommand,
        ]
        let ambientEnvironment = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "PATH", "SHELL", "TMPDIR", "USER"] {
            if let value = ambientEnvironment[key] {
                environment[key] = value
            }
        }
        environment.merge(event.environment, uniquingKeysWith: { _, eventValue in eventValue })
        environment["CMUX_SOCKET_PATH"] = event.socketPath
        environment["CMUX_BUNDLED_CLI_PATH"] = executableURL.path
        environment.removeValue(forKey: "CMUX_SOCKET")
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let input = Pipe()
        process.standardInput = input
        do {
            try process.run()
            input.fileHandleForWriting.write(Data(event.payload.utf8))
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        } catch {
            try? input.fileHandleForWriting.close()
        }
    }
}
