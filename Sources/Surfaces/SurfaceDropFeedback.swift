import CmuxCloud
import AppKit

/// Owns a transient warning above AppKit portals without taking keyboard focus.
@MainActor
final class SurfaceDropFeedback {
    private(set) var rejection: SurfaceTransferRejection?
    private var badgeView: FileDropHintBadgeView?
    var badge: FileDropHintBadgeView {
        if let badgeView { return badgeView }
        let view = FileDropHintBadgeView(frame: .zero)
        badgeView = view
        return view
    }

    func update(_ rejection: SurfaceTransferRejection?, over target: NSView) {
        guard let rejection else { clear(); return }
        let host = target.window?.contentView?.superview ?? target
        let targetBounds = host.convert(target.bounds, from: target)
        let visibleBounds = host.bounds.intersection(targetBounds)
        guard !visibleBounds.isEmpty else { clear(); return }
        let changed = self.rejection != rejection || badge.superview == nil
        self.rejection = rejection
        if badge.superview !== host {
            badge.removeFromSuperview()
            host.addSubview(badge, positioned: .above, relativeTo: nil)
        }
        // Portal stacking requires a window-level host, but the warning must
        // still fit the destination instead of covering an adjacent sidebar.
        badge.show(
            text: rejection.message,
            centeredIn: targetBounds,
            clippedTo: visibleBounds,
            warning: true
        )
        if changed, let application = NSApp {
            NSAccessibility.post(
                element: application,
                notification: .announcementRequested,
                userInfo: [.announcement: rejection.message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
        }
    }

    func clear() {
        rejection = nil
        badgeView?.hideImmediately()
        badgeView?.removeFromSuperview()
    }
}
