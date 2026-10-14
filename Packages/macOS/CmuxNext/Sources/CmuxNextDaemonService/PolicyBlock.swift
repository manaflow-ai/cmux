import CmuxNextCompat

/// Whether an administrator turned off the feature that reaches one
/// machine (`DisabledFeatures`). Read off the main actor by terminal
/// attachments; written by `FeaturePolicyEnforcer` on the main actor.
public nonisolated final class PolicyBlock: Sendable {
    private let state = Mutex(false)

    public var isBlocked: Bool { state.withLock { $0 } }

    /// `isBlocked` as a closure for attachments.
    public var check: @Sendable () -> Bool { { [self] in isBlocked } }

    public func set(_ blocked: Bool) { state.withLock { $0 = blocked } }
}
