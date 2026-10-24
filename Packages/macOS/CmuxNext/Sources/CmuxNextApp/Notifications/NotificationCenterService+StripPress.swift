import AppKit
import CmuxNextTabs

/// A press on a pane's tab strip reads its pane on the mouse-up, and only when it did not drag.
/// The press may pick up the tab or the whole pane: as in classic, where a Bonsplit tab drag
/// never dismissed, the ring then goes with the tab to wherever it is dropped.
///
/// The press also selects and focuses its tab, and a dropped tab is focused where it lands. Until
/// the person goes into the tab (a click, a key, an open), that focus is not a look at it: the
/// `focus` dismissal policy and Mark as Unread's clear on entering view skip a held tab
/// (``viewHolds``), so no kind of ring is lost to the move.
extension NotificationCenterService {
    struct StripPress {
        /// The pane's selected tab once the press was dispatched (the one it selected), taken then:
        /// by the mouse-up a close under the press has already selected a neighbor.
        let tab: String
        /// Screen coordinates, for the drag distance (a torn-off tab's mouse-up comes in another window).
        let screenLocation: NSPoint
        /// The pointer went past the tab drag distance at some point: a drag, even if it came back.
        var dragged = false
    }

    /// Where a held tab is in its move (``viewHolds``).
    enum ViewHold {
        /// The strip press is down.
        case pressing
        /// The press dragged and ended; the tab is not yet seen at its drop.
        case dropped
        /// The dropped tab was viewed: leaving view ends the hold.
        case seen
    }

    /// A strip press began on `tab` (window coordinates `location`). A press whose mouse-up a
    /// tracking loop took before this ran (the titlebar row's window drag, `WindowTitlebar`) is
    /// already over: it resolves now, from where the pointer is.
    func beginStripPress(tab: String, in window: NSWindow, at location: NSPoint) {
        stripPress = StripPress(tab: tab, screenLocation: window.convertPoint(toScreen: location))
        viewHolds[tab] = .pressing
        if !leftButtonIsDown() { noteMouseUp(in: nil, at: pointerLocation()) }
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
    /// One that dragged reads nothing, and its tab stays held until it is seen and left, or gone into.
    func noteMouseUp(in window: NSWindow?, at location: NSPoint) {
        guard let press = stripPress else { return }
        stripPress = nil
        let up = window.map { $0.convertPoint(toScreen: location) } ?? location
        if press.dragged || Self.beyondDragDistance(up, press.screenLocation) {
            if viewHolds[press.tab] == .pressing { viewHolds[press.tab] = .dropped }
            return
        }
        interacted(.click, tabID: press.tab)
    }

    /// The tabs of `viewed` whose view counts as a look (not held), advancing each hold: a
    /// dropped tab seen at its drop is `seen`, and a seen one out of view is released.
    func unheld(_ viewed: [TabModel]) -> [TabModel] {
        guard !viewHolds.isEmpty else { return viewed }
        let ids = Set(viewed.map(\.id))
        for (tab, hold) in viewHolds {
            switch hold {
            case .pressing: break
            case .dropped: if ids.contains(tab) { viewHolds[tab] = .seen }
            case .seen: if !ids.contains(tab) { viewHolds[tab] = nil }
            }
        }
        return viewed.filter { viewHolds[$0.id] == nil }
    }

    static func beyondDragDistance(_ a: NSPoint, _ b: NSPoint) -> Bool {
        hypot(a.x - b.x, a.y - b.y) > TabTunables.dragStartDistance.value
    }
}
