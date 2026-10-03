import Synchronization

/// Whether an administrator turned off the feature that reaches one
/// machine (`DisabledFeatures`). Read off the main actor by terminal
/// attachments; written by `FeaturePolicyEnforcer` on the main actor.
nonisolated final class PolicyBlock: Sendable {
    private let state = Mutex(false)

    var isBlocked: Bool { state.withLock { $0 } }

    func set(_ blocked: Bool) { state.withLock { $0 = blocked } }
}
