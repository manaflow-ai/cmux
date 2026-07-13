/// Ordered, idempotent set of actions that converges a host on the desired
/// daemon install, plus the facts the executor needs to apply them safely.
public struct VPSProvisioningPlan: Equatable, Sendable {
    /// Advisory conditions that do not stop provisioning but must be
    /// surfaced to the user.
    public enum Note: Equatable, Sendable {
        /// Host has no systemd; the daemon binary is installed but no unit
        /// is created — sessions rely on the lazy per-connection daemon and
        /// do not auto-start on reboot.
        case systemdUnavailable
        /// `loginctl enable-linger` may prompt for authorization on hosts
        /// with restrictive polkit policy; provisioning continues either way.
        case lingerBestEffort
    }

    /// Steps in execution order; empty means the host is already converged.
    public var steps: [VPSProvisioningStep]
    /// Advisory notes for the user.
    public var notes: [Note]
    /// True when applying this plan restarts a currently-active daemon,
    /// which destroys its live PTY sessions. The executor must check the
    /// daemon's live session count first and refuse without `--force`.
    public var restartDisruptsActiveDaemon: Bool

    /// Creates a plan.
    ///
    /// - Parameters:
    ///   - steps: Actions in execution order.
    ///   - notes: Advisory notes, defaults to none.
    ///   - restartDisruptsActiveDaemon: Whether applying the plan kills a
    ///     live daemon; defaults to `false`.
    public init(
        steps: [VPSProvisioningStep],
        notes: [Note] = [],
        restartDisruptsActiveDaemon: Bool = false
    ) {
        self.steps = steps
        self.notes = notes
        self.restartDisruptsActiveDaemon = restartDisruptsActiveDaemon
    }

    /// True when the host is already fully converged (only the health check
    /// remains).
    public var isAlreadyConverged: Bool {
        steps.allSatisfy { $0 == .verifyHealth }
    }
}
