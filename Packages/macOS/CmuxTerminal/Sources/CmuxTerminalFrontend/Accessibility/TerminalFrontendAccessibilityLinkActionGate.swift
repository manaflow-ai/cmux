internal import Foundation

/// Linearizable validity gate for an AppKit accessibility action callback.
///
/// AppKit can invoke an accessibility element's synchronous action method from
/// outside the main actor. The gate copies an active Sendable action under one
/// unfair lock, while invalidation atomically removes it. The copied action only
/// schedules asynchronous main-actor revalidation and performs no work inline.
final class TerminalFrontendAccessibilityLinkActionGate: @unchecked Sendable {
    private typealias Action = @Sendable () -> Void

    private let lock = NSLock()
    private var action: Action?

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func perform() -> Bool {
        lock.lock()
        let activeAction = action
        lock.unlock()
        guard let activeAction else { return false }
        activeAction()
        return true
    }

    func invalidate() {
        lock.lock()
        action = nil
        lock.unlock()
    }
}
