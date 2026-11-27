#if canImport(Darwin)
import Darwin
#endif

/// Process-group ownership for the isolated Simulator worker.
///
/// The worker becomes its own group leader before it can spawn helper
/// processes. The cmux supervisor may then terminate that exact numeric group
/// without ever signaling cmux's inherited process group.
public struct SimulatorWorkerProcessGroup: Sendable {
    /// Exit status used when the worker cannot establish its containment group.
    public static let isolationFailureExitStatus: Int32 = 76

    private let hostGroupIdentifier: Int32

    /// Creates a process-group controller with the host group it must never signal.
    /// - Parameter hostGroupIdentifier: The supervising process's group identifier.
    public init(hostGroupIdentifier: Int32 = getpgrp()) {
        self.hostGroupIdentifier = hostGroupIdentifier
    }

    /// Moves the current process into a new group led by its own PID.
    ///
    /// This must run before the worker loads private frameworks or processes its
    /// first command, so every later `xcrun`, compiler, and helper inherits the
    /// contained group.
    @discardableResult
    public func isolateCurrentProcess() -> Bool {
#if canImport(Darwin)
        let processIdentifier = getpid()
        if getpgrp() == processIdentifier { return true }
        guard setpgid(0, 0) == 0 else { return false }
        return getpgrp() == processIdentifier
#else
        return false
#endif
    }

#if canImport(Darwin)
    /// Signals a worker-owned group after rejecting unsafe identifiers.
    @discardableResult
    func signal(
        _ signal: Int32,
        groupIdentifier: Int32
    ) -> Bool {
        guard isSafeWorkerGroup(groupIdentifier) else {
            return false
        }
        return Darwin.kill(-groupIdentifier, signal) == 0
    }

    func isSafeWorkerGroup(_ groupIdentifier: Int32) -> Bool {
        groupIdentifier > 1 && groupIdentifier != hostGroupIdentifier
    }
#endif
}
