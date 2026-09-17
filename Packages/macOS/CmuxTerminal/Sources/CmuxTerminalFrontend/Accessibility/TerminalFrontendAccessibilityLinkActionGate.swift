internal import Foundation

/// Linearizable validity gate for an AppKit accessibility action callback.
///
/// AppKit can invoke an accessibility element's synchronous action method from
/// outside the main actor. The gate copies an active Sendable action under one
/// serial queue, while invalidation atomically removes it. The copied action only
/// schedules asynchronous main-actor revalidation and performs no work inline.
/// The private serial queue protects every read and write of `action`.
final class TerminalFrontendAccessibilityLinkActionGate: @unchecked Sendable {
    private typealias Action = @Sendable () -> Void

    private let isolationQueue = DispatchQueue(
        label: "com.cmux.terminal-frontend.accessibility-link-action"
    )
    private var action: Action?

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func perform() -> Bool {
        let activeAction = isolationQueue.sync { action }
        guard let activeAction else { return false }
        activeAction()
        return true
    }

    func invalidate() {
        isolationQueue.sync {
            action = nil
        }
    }
}
