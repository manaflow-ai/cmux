internal import os

/// Linearizable validity gate for an AppKit accessibility action callback.
///
/// AppKit can invoke an accessibility element's synchronous action method from
/// outside the main actor. The gate copies an active Sendable action under one
/// unfair lock, while invalidation atomically removes it. The copied action only
/// schedules asynchronous main-actor revalidation and performs no work inline.
final class TerminalFrontendAccessibilityLinkActionGate: @unchecked Sendable {
    private typealias Action = @Sendable () -> Void

    private let action: OSAllocatedUnfairLock<Action?>

    init(action: @escaping @Sendable () -> Void) {
        self.action = OSAllocatedUnfairLock(initialState: action)
    }

    func perform() -> Bool {
        guard let activeAction = action.withLock({ $0 }) else { return false }
        activeAction()
        return true
    }

    func invalidate() {
        action.withLock { $0 = nil }
    }
}
