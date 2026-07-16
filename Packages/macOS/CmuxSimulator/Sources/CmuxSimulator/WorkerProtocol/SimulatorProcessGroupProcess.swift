import Darwin
import Foundation

/// A subprocess launched in a dedicated process group.
///
/// `Foundation.Process` does not expose `POSIX_SPAWN_SETPGROUP`. Every command
/// owns its group so cancellation and leader-exit cleanup reach descendants
/// without enumerating a mutable process tree.
package actor SimulatorProcessGroupProcess {
    package nonisolated let processIdentifier: Int32

    private nonisolated let processGroup: SimulatorWorkerProcessGroup
    private nonisolated let parentLifetime: Pipe
    private var processIsRunning = true
    private var completedTerminationStatus: Int32?
    private var terminationHandler: (@Sendable (Int32) -> Void)?

    /// Launches an executable with absent standard descriptors redirected to
    /// `/dev/null`.
    package init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        standardOutputFD: Int32? = nil,
        standardErrorFD: Int32? = nil,
        fileDescriptorsToClose: [Int32] = [],
        launcher: SimulatorPOSIXProcessLauncher = SimulatorPOSIXProcessLauncher()
    ) throws {
        let parentLifetime = Pipe()
        self.parentLifetime = parentLifetime
        processGroup = SimulatorWorkerProcessGroup()
        do {
            processIdentifier = try launcher.launch(
                executableURL: SimulatorParentLifetimeSupervisor.executableURL,
                arguments: SimulatorParentLifetimeSupervisor.arguments(
                    executableURL: executableURL,
                    arguments: arguments
                ),
                environment: environment,
                currentDirectoryURL: currentDirectoryURL,
                standardInputFD: parentLifetime.fileHandleForReading.fileDescriptor,
                standardOutputFD: standardOutputFD,
                standardErrorFD: standardErrorFD,
                fileDescriptorsToClose: fileDescriptorsToClose + [
                    parentLifetime.fileHandleForReading.fileDescriptor,
                    parentLifetime.fileHandleForWriting.fileDescriptor,
                ]
            )
        } catch {
            try? parentLifetime.fileHandleForReading.close()
            try? parentLifetime.fileHandleForWriting.close()
            throw error
        }
        try? parentLifetime.fileHandleForReading.close()
        startReaper()
    }

    deinit {
        guard processIsRunning else { return }
        _ = signalOwnedScope(SIGKILL)
        try? parentLifetime.fileHandleForWriting.close()
    }

    package var isRunning: Bool {
        processIsRunning
    }

    package var terminationStatus: Int32? {
        completedTerminationStatus
    }

    /// Installs the single leader-termination callback. If the leader already
    /// exited, the callback runs immediately with its decoded status.
    package func setTerminationHandler(
        _ handler: @escaping @Sendable (Int32) -> Void
    ) {
        if let completedTerminationStatus {
            handler(completedTerminationStatus)
        } else {
            terminationHandler = handler
        }
    }

    /// Signals the complete command group owned by this wrapper.
    @discardableResult
    package nonisolated func signalOwnedScope(_ signal: Int32) -> Bool {
        processGroup.signal(signal, groupIdentifier: processIdentifier)
    }

    package nonisolated func interrupt() {
        _ = signalOwnedScope(SIGINT)
    }

    package nonisolated func terminate() {
        _ = signalOwnedScope(SIGTERM)
    }

    package nonisolated func forceKill() {
        _ = signalOwnedScope(SIGKILL)
    }

    private nonisolated func startReaper() {
        let processIdentifier = processIdentifier
        let processGroup = processGroup
        let thread = Thread { [weak self] in
            var rawStatus: Int32 = 0
            var waitResult: pid_t
            repeat {
                waitResult = waitpid(processIdentifier, &rawStatus, 0)
            } while waitResult == -1 && errno == EINTR

            let status = waitResult == processIdentifier
                ? (self?.decodedTerminationStatus(rawStatus) ?? -1)
                : -1
            // The leader is reaped, but descendants may still retain pipes or
            // ignore an earlier signal. This group is exclusively ours.
            _ = processGroup.signal(SIGKILL, groupIdentifier: processIdentifier)
            try? self?.parentLifetime.fileHandleForWriting.close()
            Task {
                await self?.recordTermination(status)
            }
        }
        thread.name = "cmux-simulator-process-reaper"
        thread.stackSize = 1 << 20
        thread.start()
    }

    private func recordTermination(_ status: Int32) {
        guard processIsRunning else { return }
        processIsRunning = false
        completedTerminationStatus = status
        let handler = terminationHandler
        terminationHandler = nil
        handler?(status)
    }

    private nonisolated func decodedTerminationStatus(_ rawStatus: Int32) -> Int32 {
        let terminatingSignal = rawStatus & 0x7f
        if terminatingSignal == 0 {
            return (rawStatus >> 8) & 0xff
        }
        return terminatingSignal
    }
}
