import AppKit
import Foundation

/// Batches terminal-driven window-title writes before they cross the AppKit
/// WindowServer boundary.
///
/// A terminal title is presentation metadata, so dropping intermediate values
/// is safe: the newest value is the only one that matters once the burst ends.
/// The gate also remembers the last value written to each current window and
/// skips no-op assignments, which otherwise still notify Dock and Spaces.
@MainActor
final class WindowTitleUpdateGate {
    /// One second is long enough to collapse agent spinner churn while keeping
    /// the final title responsive after a command settles.
    static let defaultDelay: TimeInterval = 1.0

    private let coalescer: NotificationBurstCoalescer
    private weak var pendingWindow: NSWindow?
    private var pendingTitle: String?
    private weak var lastAppliedWindow: NSWindow?
    private var lastAppliedTitle: String?

    init(coalescer: NotificationBurstCoalescer? = nil) {
        self.coalescer = coalescer ?? NotificationBurstCoalescer(delay: Self.defaultDelay)
    }

    /// Queues the newest title for a terminal-driven update.
    func submit(_ title: String, to window: NSWindow) {
        guard !isAlreadyApplied(title, to: window) else { return }
        guard pendingTitle != title || pendingWindow !== window else { return }
        pendingWindow = window
        pendingTitle = title
        coalescer.signal(delay: Self.defaultDelay) { [weak self] in
            self?.flushPendingTitle()
        }
    }

    /// Applies a user-initiated or lifecycle title change immediately.
    /// Pending terminal metadata is flushed first so a stale delayed value
    /// cannot overwrite the explicit title.
    func applyImmediately(_ title: String, to window: NSWindow) {
        coalescer.flushNow()
        pendingWindow = nil
        pendingTitle = nil
        apply(title, to: window)
    }

    /// Delivers a pending terminal title at a lifecycle boundary.
    func flushNow() {
        coalescer.flushNow()
    }

    private func flushPendingTitle() {
        guard let pendingWindow, let pendingTitle else { return }
        self.pendingWindow = nil
        self.pendingTitle = nil
        apply(pendingTitle, to: pendingWindow)
    }

    private func apply(_ title: String, to window: NSWindow) {
        guard !isAlreadyApplied(title, to: window) else { return }
        window.title = title
        lastAppliedWindow = window
        lastAppliedTitle = title
    }

    private func isAlreadyApplied(_ title: String, to window: NSWindow) -> Bool {
        lastAppliedWindow === window && lastAppliedTitle == title
    }
}
