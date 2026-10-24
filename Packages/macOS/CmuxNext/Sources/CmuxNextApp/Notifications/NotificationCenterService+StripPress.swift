import AppKit
import CmuxNextTabs

/// A press on a pane's tab strip reads its pane on the mouse-up, and only when it did not drag.
/// The press may pick up the tab or the whole pane: as in classic, where a Bonsplit tab drag
/// never dismissed, the ring then goes with the tab to wherever it is dropped.
extension NotificationCenterService {
    struct StripPress {
        /// The pane's selected tab once the press was dispatched (the one it selected), taken then:
        /// by the mouse-up a close under the press has already selected a neighbor.
        let tab: String
        /// Screen coordinates, for the drag distance (a torn-off tab's mouse-up comes in another window).
        let screenLocation: NSPoint
    }

    /// A left mouse-up landed in `window` at `location` (window coordinates, after AppKit
    /// dispatched it): a strip press that stayed within the tab drag distance was a click, and
    /// reads the tab the press left selected in its pane.
    func noteMouseUp(in window: NSWindow?, at location: NSPoint) {
        guard let press = stripPress else { return }
        stripPress = nil
        let up = window.map { $0.convertPoint(toScreen: location) } ?? NSEvent.mouseLocation
        guard hypot(up.x - press.screenLocation.x, up.y - press.screenLocation.y) <= TabTunables.dragStartDistance.value else { return }
        interacted(.click, tabID: press.tab)
    }
}
