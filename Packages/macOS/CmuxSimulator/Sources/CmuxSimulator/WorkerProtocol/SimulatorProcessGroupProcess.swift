import Darwin
import Foundation

/// A subprocess launched with an explicit process-group ownership policy.
///
/// `Foundation.Process` does not expose `POSIX_SPAWN_SETPGROUP`. Simulator
/// host commands own dedicated groups so command-local cancellation reaches
/// descendants. Worker commands inherit the worker group so a worker crash or
/// host cleanup cannot strand helpers outside the worker's lifecycle boundary.
package actor SimulatorProcessGroupProcess {
    package nonisolated let processIdentifier: Int32

    private nonisolated let launchGrouping: SimulatorProcessLaunchGrouping
    private nonisolated let processGroup: SimulatorWorkerProcessGroup
    private nonisolated let inheritedProcessTree: SimulatorInheritedProcessTree?
    private var processIsRunning = true
    private var completedTerminationStatus: Int32?
    private var terminationHandler: (@Sendable (Int32) -> Void)?

    /// Launches an executable with the requested process-group ownership.
    ///
    /// Standard input is always `/dev/null`; absent output descriptors are also
    /// redirected to `/dev/null`.
    package init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        standardOutputFD: Int32? = nil,
        standardErrorFD: Int32? = nil,
        fileDescriptorsToClose: [Int32] = [],
        grouping: SimulatorProcessLaunchGrouping,
        launcher: SimulatorPOSIXProcessLauncher = SimulatorPOSIXProcessLauncher()
    ) throws {
        processIdentifier = try launcher.launch(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            standardOutputFD: standardOutputFD,
            standardErrorFD: standardErrorFD,
            fileDescriptorsToClose: fileDescriptorsToClose,
            grouping: grouping
        )
        launchGrouping = grouping
        processGroup = SimulatorWorkerProcessGroup()
        inheritedProcessTree = switch grouping {
        case .dedicatedProcessGroup: nil
        case .inheritedProcessGroup:
            SimulatorInheritedProcessTree(rootProcessIdentifier: processIdentifier)
        }
        startReaper()
    }

    deinit {
        guard processIsRunning else { return }
        _ = signalOwnedScope(SIGKILL)
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

    /// Signals the scope owned by this wrapper.
    ///
    /// Dedicated launches signal the complete command group. Inherited launches
    /// signal only the direct child because their group also contains the worker
    /// and its unrelated commands.
    @discardableResult
    package nonisolated func signalOwnedScope(_ signal: Int32) -> Bool {
        switch launchGrouping {
        case .dedicatedProcessGroup:
            if processGroup.signal(signal, groupIdentifier: processIdentifier) {
                return true
            }
            return Darwin.kill(processIdentifier, signal) == 0
        case .inheritedProcessGroup:
            return inheritedProcessTree?.signal(signal) ?? false
        }
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
        let launchGrouping = launchGrouping
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
            if launchGrouping == .dedicatedProcessGroup {
                // The leader is reaped, but descendants may still retain pipes
                // or ignore an earlier signal. This group is exclusively ours.
                _ = processGroup.signal(SIGKILL, groupIdentifier: processIdentifier)
            }
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

/// Signals one command tree without widening the signal to the worker's shared
/// process group. Descendants discovered for TERM remain retained so the KILL
/// escalation still reaches them after the command leader has exited and they
/// have been reparented by launchd.
private final class SimulatorInheritedProcessTree: @unchecked Sendable {
    private static let maximumDescendants = 4_096

    private let rootProcessIdentifier: pid_t
    private let lock = NSLock()
    private var retainedDescendants: Set<pid_t> = []

    init(rootProcessIdentifier: pid_t) {
        self.rootProcessIdentifier = rootProcessIdentifier
    }

    @discardableResult
    func signal(_ signal: Int32) -> Bool {
        let discovered = Self.descendantsChildFirst(
            of: rootProcessIdentifier,
            limit: Self.maximumDescendants
        )
        let descendants = lock.withLock { () -> [pid_t] in
            retainedDescendants.formUnion(discovered)
            return discovered + Array(retainedDescendants.subtracting(discovered))
        }
        var signalled = false
        for processIdentifier in descendants where processIdentifier > 1 {
            if Darwin.kill(processIdentifier, signal) == 0 || errno == ESRCH {
                signalled = true
            }
        }
        if Darwin.kill(rootProcessIdentifier, signal) == 0 || errno == ESRCH {
            signalled = true
        }
        return signalled
    }

    private static func descendantsChildFirst(
        of root: pid_t,
        limit: Int
    ) -> [pid_t] {
        var result: [pid_t] = []
        var visited: Set<pid_t> = []
        var pending: [(processIdentifier: pid_t, expanded: Bool)] = [(root, false)]
        while let next = pending.popLast(), result.count < limit {
            if next.expanded {
                if next.processIdentifier != root { result.append(next.processIdentifier) }
                continue
            }
            guard visited.insert(next.processIdentifier).inserted else { continue }
            pending.append((next.processIdentifier, true))
            for child in directChildren(of: next.processIdentifier).reversed()
                where visited.count + pending.count <= limit {
                pending.append((child, false))
            }
        }
        return result
    }

    private static func directChildren(of parent: pid_t) -> [pid_t] {
        var capacity = 16
        let stride = MemoryLayout<pid_t>.stride
        var lastResult: [pid_t] = []
        for _ in 0..<4 {
            var children = Array(repeating: pid_t(), count: capacity)
            let returned = children.withUnsafeMutableBufferPointer { buffer in
                proc_listchildpids(
                    parent,
                    buffer.baseAddress,
                    Int32(buffer.count * stride)
                )
            }
            guard returned >= 0 else { return lastResult }
            let count = min(children.count, Int(returned))
            lastResult = children.prefix(count).filter { $0 > 1 }
            if Int(returned) < children.count { return lastResult }
            capacity = max(capacity * 2, Int(returned) + 16)
        }
        return lastResult
    }
}
