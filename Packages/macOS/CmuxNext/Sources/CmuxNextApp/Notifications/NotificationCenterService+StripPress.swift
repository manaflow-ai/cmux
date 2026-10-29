import AppKit
import CmuxNextDaemon
import CmuxNextTabs

/// A press on a pane's tab strip reads its pane on the mouse-up, and only when it did not drag.
/// The press may pick up the tab or the whole pane: as in classic, where a Bonsplit tab drag
/// never dismissed, the ring then goes with the tab to wherever it is dropped.
///
/// The press also selects and focuses its tab, and a dropped tab is focused where it lands, in
/// whatever order the daemon's echo and the focus settle. Neither is a look: the tab is held
/// (``viewHolds``) until the person's next input (a press anywhere, a key), so the `focus`
/// dismissal policy and Mark as Unread's clear on coming into view skip it until then. A click or
/// a key in the tab itself reads it as always.
extension NotificationCenterService {
    struct StripPress {
        /// The pane's selected tab once the press was dispatched (the one it selected), taken then:
        /// by the mouse-up a close under the press has already selected a neighbor.
        let tab: String
        /// Where it went down (screen coordinates; a torn-off tab's mouse-up comes in another window).
        let screenLocation: NSPoint
        /// The pointer went past the tab drag distance at some point: a drag, even if it came back.
        var dragged = false
    }

    /// A strip press began on `tab` at `screenLocation`. A press whose mouse-up a tracking loop took
    /// before this ran (the titlebar row's window drag, `WindowTitlebar`) is already over: it
    /// resolves now, from where the pointer is. The app's own input has no hardware button to ask.
    func beginStripPress(tab: String, at screenLocation: NSPoint, synthetic: Bool) {
        stripPress = StripPress(tab: tab, screenLocation: screenLocation)
        viewHolds.insert(tab)
        if !synthetic, !leftButtonIsDown() { noteMouseUp(in: nil, at: pointerLocation()) }
    }

    /// A left-button drag event: marks the press a drag once it leaves the drag distance.
    func noteMouseDragged(in window: NSWindow?, at location: NSPoint) {
        guard var press = stripPress, !press.dragged else { return }
        let point = window.map { $0.convertPoint(toScreen: location) } ?? location
        guard Self.beyondDragDistance(point, press.screenLocation) else { return }
        press.dragged = true
        stripPress = press
    }

    /// A left mouse-up landed in `window` at `location` (window coordinates, after AppKit
    /// dispatched it; screen coordinates when `window` is nil): a strip press that never left
    /// the tab drag distance was a click, and reads the tab the press left selected in its pane.
    /// One that dragged reads nothing, and its tab stays held until the next input.
    func noteMouseUp(in window: NSWindow?, at location: NSPoint) {
        guard let press = stripPress else { return }
        stripPress = nil
        let up = window.map { $0.convertPoint(toScreen: location) } ?? location
        if press.dragged || Self.beyondDragDistance(up, press.screenLocation) { return }
        // A click: the hold ends here, also for a tab the click closed (no tab left to read).
        viewHolds.remove(press.tab)
        interacted(.click, tabID: press.tab)
    }

    /// The person's next input after a move (a key-down; a press calls it too): every hold ends,
    /// unless a strip press is still down.
    func endViewHolds() {
        guard !viewHolds.isEmpty, stripPress == nil else { return }
        viewHolds.removeAll()
    }

    /// The tabs of `viewed` whose view counts as a look: the ones no strip press holds.
    func unheld(_ viewed: [TabModel]) -> [TabModel] {
        viewHolds.isEmpty ? viewed : viewed.filter { !viewHolds.contains($0.id) }
    }

    static func beyondDragDistance(_ a: NSPoint, _ b: NSPoint) -> Bool {
        hypot(a.x - b.x, a.y - b.y) > TabTunables.dragStartDistance.value
    }
}
