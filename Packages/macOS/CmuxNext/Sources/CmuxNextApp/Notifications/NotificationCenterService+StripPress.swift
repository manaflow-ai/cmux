import AppKit
import CmuxNextTabs

/// A press on a pane's tab strip reads its pane on the mouse-up, and only when it did not drag.
/// The press may pick up the tab or the whole pane: as in classic, where a Bonsplit tab drag
/// never dismissed, the ring then goes with the tab to wherever it is dropped.
extension NotificationCenterService {
    struct StripPress {
        weak var window: NSWindow?
        /// Window coordinates, for the pane hit test.
        let location: NSPoint
        /// Screen coordinates, for the drag distance (a torn-off tab's mouse-up comes in another window).
        let screenLocation: NSPoint
    }

    /// A left mouse-up landed in `window` at `location` (window coordinates, after AppKit
    /// dispatched it): a strip press that stayed within the tab drag distance was a click, and
    /// reads the pane's selected tab (the one the press selected).
    func noteMouseUp(in window: NSWindow?, at location: NSPoint) {
        guard let press = stripPress else { return }
        stripPress = nil
        let up = window.map { $0.convertPoint(toScreen: location) } ?? NSEvent.mouseLocation
        guard let window = press.window else { return }
        guard hypot(up.x - press.screenLocation.x, up.y - press.screenLocation.y) <= TabTunables.dragStartDistance.value,
              let tab = clickedTab(in: window, at: press.location) else { return }
        interacted(.click, tabID: tab)
    }

    /// Whether `location` (window coordinates) is on a tab strip, the way `PaneSwapDrag` finds it.
    static func pressesTabStrip(in window: NSWindow, at location: NSPoint) -> Bool {
        guard let frame = window.contentView?.superview else { return false }
        var view = frame.hitTest(frame.convert(location, from: nil))
        while let current = view, !(current is TabStripView) { view = current.superview }
        return view != nil
    }
}
