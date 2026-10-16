import AppKit
import CmuxFoundation

/// Shows a ``TerminalPasteFailureNotice`` briefly over one terminal.
///
/// Reuses the warning badge a rejected drop shows (``FileDropHintBadgeView``,
/// as ``SurfaceDropFeedback`` does). The badge is a subview of the terminal's
/// scroll view, like the image-transfer indicator, so it goes away with the
/// terminal. It ignores hit testing, never takes focus, and hides itself after
/// ``displayDuration``. A newer notice replaces the one on screen.
@MainActor
final class TerminalPasteFailureNoticePresenter {
    static let displayDuration: Duration = .seconds(3)

    private var badgeView: FileDropHintBadgeView?
    private var deadline: MainActorCoalescingDeadlineTimer<TerminalPasteFailureNoticePresenter>?

    func show(_ notice: TerminalPasteFailureNotice, over host: NSView) {
        let badge = badgeView ?? FileDropHintBadgeView(frame: .zero)
        badgeView = badge
        // Re-adding moves the badge above overlays mounted since the last notice.
        badge.removeFromSuperview()
        host.addSubview(badge, positioned: .above, relativeTo: nil)
        let message = notice.message
        badge.show(
            text: message,
            centeredIn: host.bounds,
            clippedTo: host.bounds,
            warning: true
        )
        if let application = NSApp {
            NSAccessibility.post(
                element: application,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
        if deadline == nil {
            // A display deadline for the notice, not a retry loop.
            deadline = MainActorCoalescingDeadlineTimer(owner: self) { $0.dismiss() }
        }
        deadline?.schedule(after: Self.displayDuration)
    }

    func dismiss() {
        deadline?.cancel()
        badgeView?.hideImmediately()
        badgeView?.removeFromSuperview()
    }
}
