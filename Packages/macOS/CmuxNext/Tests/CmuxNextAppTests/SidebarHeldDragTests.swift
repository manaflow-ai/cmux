import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-21: "AND THEN THE HELD DRAGGED, IT GETS STUCK". A press on a workspace row switches to it, and a
/// workspace showing a Chromium page or agent page gives the page's child window the keys a moment later: the
/// sidebar's window resigns key while the button is still held. The list ended the gesture there, so a held press
/// never lifted its row, and a lifted row flew back and stopped following the pointer. Every drag still has to end:
/// on release, after a release that went to another window, at the app's next press when its release never came,
/// and when the app loses focus.
/// Uses `SidebarPointerGestureTests`' list: loose `x`, `y`; group `g1` (`a`, `b`); collapsed group `g2` (`c`, `d`).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarHeldDragTests {
    typealias G = SidebarPointerGestureTests

    /// A drop's or a cancel's card is gone and its rows show (the flight ends at once here).
    static func land(_ list: SidebarListView) {
        if let landing = list.landing { list.finishLand(landing, then: nil) }
    }

    static func drag(_ list: SidebarListView, from start: NSPoint, dy: CGFloat) throws {
        list.mouseDragged(with: try G.event(list, .leftMouseDragged, at: NSPoint(x: start.x, y: start.y + dy)))
    }

    // MARK: - The keys move to a child window while the button is held

    @Test func aHeldPressStillLiftsAfterThePageWindowTookTheKeys() throws {
        let (list, window) = G.list()
        defer { window.close() }
        list.leftButtonIsDown = { true }
        let order = G.ids(list)
        let start = try G.point(list, .workspace(WorkspaceID("x")))
        list.mouseDown(with: try G.event(list, .leftMouseDown, at: start))
        // The press switched to x; x's page window becomes key while the button is held.
        list.pointerWindowLostKey()
        #expect(list.press != nil, "the window's key change dropped the held press")
        for dy: CGFloat in [10, 30, 60] { try Self.drag(list, from: start, dy: dy) }
        #expect(list.drag != nil, "the held press never lifted its row: the drag is stuck")
        list.leftButtonIsDown = { false }
        list.mouseUp(with: try G.event(list, .leftMouseUp, at: NSPoint(x: start.x, y: start.y + 60)))
        Self.land(list)
        #expect(list.drag == nil && list.press == nil && list.landing == nil)
        #expect(G.ids(list) != order, "the drop moved nothing: \(G.ids(list))")
        #expect(list.suppressed.isEmpty, "rows still hidden: \(list.suppressed)")
    }

    @Test func aLiftedRowKeepsFollowingThePointerAfterThePageWindowTookTheKeys() throws {
        let (list, window) = G.list()
        defer { window.close() }
        list.leftButtonIsDown = { true }
        let order = G.ids(list)
        let start = try G.point(list, .workspace(WorkspaceID("x")))
        try G.press(list, at: start, moves: [CGVector(dx: 0, dy: 10), CGVector(dx: 0, dy: 20)], release: false)
        let drag = try #require(list.drag, "a 20 pt move did not lift the row")
        let before = drag.lift.frame.minY
        list.pointerWindowLostKey()
        #expect(list.drag === drag, "the window's key change cancelled the held drag")
        try Self.drag(list, from: start, dy: 60)
        #expect(list.drag === drag)
        #expect(drag.lift.frame.minY > before, "the lifted row stopped following the pointer")
        list.leftButtonIsDown = { false }
        list.mouseUp(with: try G.event(list, .leftMouseUp, at: NSPoint(x: start.x, y: start.y + 60)))
        Self.land(list)
        #expect(list.drag == nil && list.press == nil && list.landing == nil)
        #expect(G.ids(list) != order, "the drop moved nothing: \(G.ids(list))")
        #expect(list.suppressed.isEmpty, "rows still hidden: \(list.suppressed)")
    }

    // MARK: - Every drag still ends

    @Test func aKeyLossAfterTheButtonCameUpEndsTheDragWithItsRowsBack() throws {
        let (list, window) = G.list()
        defer { window.close() }
        list.leftButtonIsDown = { true }
        let order = G.ids(list)
        let start = try G.point(list, .workspace(WorkspaceID("x")))
        try G.press(list, at: start, moves: [CGVector(dx: 0, dy: 10), CGVector(dx: 0, dy: 40)], release: false)
        #expect(list.drag != nil)
        // The release went to another window; this window then lost the keys.
        list.leftButtonIsDown = { false }
        list.pointerWindowLostKey()
        #expect(list.drag == nil && list.press == nil, "a drag whose release went elsewhere stayed alive")
        Self.land(list)
        #expect(G.ids(list) == order, "a cancelled drag moved rows: \(G.ids(list))")
        #expect(list.suppressed.isEmpty, "rows still hidden: \(list.suppressed)")
    }

    @Test func aDragWhoseReleaseNeverCameEndsAtTheAppsNextPressAnywhere() throws {
        let (list, window) = G.list()
        defer { window.close() }
        list.leftButtonIsDown = { true }
        let order = G.ids(list)
        let start = try G.point(list, .workspace(WorkspaceID("x")))
        try G.press(list, at: start, moves: [CGVector(dx: 0, dy: 10), CGVector(dx: 0, dy: 40)], release: false)
        #expect(list.drag != nil)
        // No release reaches the list (a tracking loop ate it). The next press lands in a pane, not the list.
        let other = NSWindow(contentRect: NSRect(x: 400, y: 100, width: 200, height: 200), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        #expect(list.pointerEventSeen(.leftMouseDown, in: other), "the app's next press left the drag alive")
        #expect(list.drag == nil && list.press == nil)
        Self.land(list)
        #expect(G.ids(list) == order, "the lost drag dropped: \(G.ids(list))")
        #expect(list.suppressed.isEmpty, "rows still hidden: \(list.suppressed)")
    }

    @Test func aReleaseSentToAnotherWindowEndsTheDragOnceItsDispatchIsOver() async throws {
        let (list, window) = G.list()
        defer { window.close() }
        list.leftButtonIsDown = { true }
        let order = G.ids(list)
        let start = try G.point(list, .workspace(WorkspaceID("x")))
        try G.press(list, at: start, moves: [CGVector(dx: 0, dy: 10), CGVector(dx: 0, dy: 40)], release: false)
        #expect(list.drag != nil)
        let other = NSWindow(contentRect: NSRect(x: 400, y: 100, width: 200, height: 200), styleMask: [.borderless],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        list.leftButtonIsDown = { false }
        // A panel over the window may still forward the release here: nothing ends during its dispatch.
        #expect(!list.pointerEventSeen(.leftMouseUp, in: other))
        #expect(list.drag != nil)
        // Its dispatch is over and the list never got it: the drag ends, its rows back.
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(list.drag == nil && list.press == nil, "a drag whose release went to another window stayed alive")
        Self.land(list)
        #expect(G.ids(list) == order, "a cancelled drag moved rows: \(G.ids(list))")
        #expect(list.suppressed.isEmpty, "rows still hidden: \(list.suppressed)")
    }

    @Test func aReleaseInTheListsOwnWindowDropsThroughMouseUpAlone() throws {
        let (list, window) = G.list()
        defer { window.close() }
        list.leftButtonIsDown = { true }
        let start = try G.point(list, .workspace(WorkspaceID("x")))
        try G.press(list, at: start, moves: [CGVector(dx: 0, dy: 10), CGVector(dx: 0, dy: 60)], release: false)
        let drag = try #require(list.drag)
        // The monitor sees the release before the list does and leaves it to `mouseUp`.
        #expect(!list.pointerEventSeen(.leftMouseUp, in: window))
        #expect(list.drag === drag)
        list.leftButtonIsDown = { false }
        list.mouseUp(with: try G.event(list, .leftMouseUp, at: NSPoint(x: start.x, y: start.y + 60)))
        Self.land(list)
        #expect(list.drag == nil && list.press == nil && list.suppressed.isEmpty)
    }
}
