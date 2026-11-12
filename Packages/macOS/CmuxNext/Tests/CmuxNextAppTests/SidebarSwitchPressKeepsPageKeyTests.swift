import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextFocus
@testable import CmuxNextSidebar
import Testing

/// SPACE SWITCH 4 (hold l1, aws-m4pro-8, 120 Hz, twin 646125b19f9b, gated for the host clock): a workspace switch by
/// a sidebar click shows its frame 18.2 and 14.8 ms later at p50 than the same switch by its key (the 2 rounds: 51.55
/// and 48.40 ms against 33.38 and 33.57 ms; Chrome's tab switch: 33.20 and 36.94 ms). The cause is a change of the key window that the
/// person cannot see. While a Chromium page holds the key (a browser tab, an agent chat, Home), a press on a row went
/// `ShellWindow.sendEvent` -> `WindowPressRouter.willSend` -> `FirstClickPolicy` -> `makeKey` BEFORE the row got the
/// press (the press was 10.23 ms old at p50 when the switch started; 2.7 to 3.0 ms with a terminal, where no key moves), and the
/// row's `mouseDown` then made the list the first responder, for which the focus model takes the keys back from the
/// page (`FocusEffectApplier.moveResponder(.sidebar)` -> `ChildPageFocus.reclaim`). The key change's layout and
/// draw of the window landed in the frame of the switch (commit - apply 13.58 ms by click, 6.3 ms by key). The
/// switch then gives the keyboard to the new workspace's content, so the shell window was key for nothing.
///
/// Chrome: the tab strip and the page are in ONE NSWindow, which stays key through a tab click; the click shows the
/// other tab's view (`RenderWidgetHostViewMac::ShowWithVisibility`,
/// content/browser/renderer_host/render_widget_host_view_mac.mm) and no key window changes.
///
/// The rule here: a row press that shows another workspace asks for no key change and puts no keyboard on the list;
/// the keyboard goes to the new workspace's content in the turn of the press, as it does for the key. A press that
/// shows no other workspace (the shown row, a rename, a menu, a selection change) keeps the key behaviour it had.
/// Test windows are never key, so the app's key state comes in through the window's press router
/// (`WindowPressRouter.appKeyState`), its key requests are counted (`makeKey`), and the focus model's reports of the
/// list as the first responder are counted from its observer. No assertion holds a time.
@MainActor @Suite(.serialized)
struct SidebarSwitchPressKeepsPageKeyTests {
    @MainActor final class Rig {
        let bench: SpaceSwitchBench
        let window: ShellWindow
        /// A Chromium page: a child window of the shell window, holding the key.
        let page: NSWindow
        /// Times the press router asked to make the shell window key.
        private(set) var keyRequests = 0
        /// Times the focus model heard that the sidebar list is the first responder.
        private(set) var listReports = 0

        init() async throws {
            bench = try await SpaceSwitchSameTurnTests.bench()
            window = try #require(bench.controller.window as? ShellWindow, "the bench's window is not a ShellWindow")
            window.contentView?.layoutSubtreeIfNeeded()
            // A defined start: the list does not hold the keyboard (a page does).
            window.makeFirstResponder(nil)
            let page = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered,
                                defer: true)
            page.isReleasedWhenClosed = false
            window.addChildWindow(page, ordered: .above)
            self.page = page
            window.presses.appKeyState = { [weak page, weak window] in
                AppKeyState(keyWindow: page, mainWindow: window, isActive: true, isModal: false)
            }
            window.presses.makeKey = { [weak self] _ in self?.keyRequests += 1 }
            let focus = bench.controller.focus, earlier = focus.observer
            focus.observer = { [weak self] observation in
                earlier?(observation)
                switch observation {
                case .reduced(.responder(.sidebar, source: _), before: _, after: _, changed: _), .suppressedResponder(.sidebar):
                    self?.listReports += 1
                default: break
                }
            }
        }

        func close() {
            window.removeChildWindow(page)
            page.close()
            bench.close()
        }

        var list: SidebarListView { bench.list }

        /// A listed workspace of the shown space that the window does not show.
        func otherWorkspace() throws -> String {
            let shown = try #require(bench.shownWorkspace, "the window shows no workspace")
            let listed = (bench.keysByRoom[bench.rooms[0]] ?? []).filter { list.displayed.row(for: .workspace(WorkspaceID($0))) != nil }
            return try #require(listed.first { $0 != shown }, "the list shows no other workspace than \(shown): \(listed)")
        }

        /// The middle of `workspace`'s row, in the window.
        func point(ofRow workspace: String) throws -> NSPoint {
            let row = try #require(list.displayed.row(for: .workspace(WorkspaceID(workspace))), "no row for \(workspace)")
            return list.convert(NSPoint(x: 80, y: row.y + row.height / 2), to: nil)
        }

        func event(_ type: NSEvent.EventType, _ point: NSPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                            pressure: type == .leftMouseUp ? 0 : 1))
        }

        /// The press as the window gets it (`ShellWindow.sendEvent`, the path of a real click and of `debug.mouse`).
        func send(_ type: NSEvent.EventType, _ point: NSPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) throws {
            window.sendEvent(try event(type, point, flags: flags, clicks: clicks))
        }
    }

    /// The whole path of a click: the window's `sendEvent`. With a page key, the press shows the other workspace in
    /// its own turn, with no key request before the row gets it and no keyboard on the list after.
    @Test func aRowPressThatShowsAnotherWorkspaceWhileAPageHoldsTheKeyAsksForNoKeyChange() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        let target = try rig.otherWorkspace()
        let point = try rig.point(ofRow: target)
        try #require(rig.window.contentView?.hitTest(point) === rig.list, "the press at \(point) does not land on the list: the rig is wrong")
        try rig.send(.leftMouseDown, point)
        #expect(rig.keyRequests == 0, "the row press asked to make the shell window key \(rig.keyRequests)x before the row got it: the page loses the key")
        #expect(rig.listReports == 0, "the row press put the keyboard on the list \(rig.listReports)x: the focus model takes the keys back from the page")
        #expect(rig.bench.shownWorkspace == target, "the press did not show \(target) in its own turn: the window shows \(rig.bench.shownWorkspace ?? "nothing")")
        try rig.send(.leftMouseUp, point)
        #expect(rig.keyRequests == 0, "the release asked for \(rig.keyRequests) key changes")
        #expect(rig.bench.shownWorkspace == target, "the release left \(target): the window shows \(rig.bench.shownWorkspace ?? "nothing")")
    }

    /// The row's own part, with no window path: the press shows the workspace and leaves the keyboard to the focus
    /// model (the new workspace's content); the list is not the first responder between the two.
    @Test func aRowPressThatShowsAnotherWorkspaceDoesNotPutTheKeyboardOnTheList() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        let target = try rig.otherWorkspace()
        let point = try rig.point(ofRow: target)
        rig.list.mouseDown(with: try rig.event(.leftMouseDown, point))
        #expect(rig.bench.shownWorkspace == target, "the press did not show \(target): the window shows \(rig.bench.shownWorkspace ?? "nothing")")
        #expect(rig.listReports == 0, "the press made the list the first responder \(rig.listReports)x")
        #expect(rig.window.firstResponder !== rig.list, "the list holds the keyboard after a press that showed another workspace")
        rig.list.mouseUp(with: try rig.event(.leftMouseUp, point))
    }

    /// A press on the row of the shown workspace shows nothing else: it acts at once as before (the window is made
    /// key first, `FirstClickPolicy`), and the list takes the keyboard (the arrow keys then move in the list).
    @Test func aPressOnTheShownRowKeepsTheKeyBehaviourItHad() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        let shown = try #require(rig.bench.shownWorkspace)
        let point = try rig.point(ofRow: shown)
        try rig.send(.leftMouseDown, point)
        try rig.send(.leftMouseUp, point)
        #expect(rig.keyRequests == 1, "a press on the shown row made \(rig.keyRequests) key requests (want 1)")
        rig.list.mouseDown(with: try rig.event(.leftMouseDown, point))
        rig.list.mouseUp(with: try rig.event(.leftMouseUp, point))
        #expect(rig.window.firstResponder === rig.list, "a press on the shown row did not put the keyboard on the list")
        #expect(rig.bench.shownWorkspace == shown)
    }

    /// Presses on another workspace's row that show nothing at the press keep the key behaviour they had: a
    /// control-press (its menu), a Command-press (the selection), a Shift-press (the range) and the second press of a
    /// double-click (the rename). Each makes the window key first, as before.
    @Test func aRowPressThatShowsNothingKeepsTheKeyBehaviourItHad() async throws {
        let cases: [(name: String, flags: NSEvent.ModifierFlags, clicks: Int)] = [
            ("control", .control, 1), ("command", .command, 1), ("shift", .shift, 1), ("double-click", [], 2),
        ]
        for press in cases {
            let rig = try await Rig()
            defer { rig.close() }
            let shown = try #require(rig.bench.shownWorkspace)
            let point = try rig.point(ofRow: try rig.otherWorkspace())
            try rig.send(.leftMouseDown, point, flags: press.flags, clicks: press.clicks)
            try rig.send(.leftMouseUp, point, flags: press.flags, clicks: press.clicks)
            #expect(rig.keyRequests == 1, "a \(press.name) press on a row made \(rig.keyRequests) key requests (want 1)")
            // AppKit does not deliver a sent press to a view of a window that is not on screen, so the row gets the
            // same press directly: what the list shows after it is the row's own answer, not the rig's.
            rig.list.mouseDown(with: try rig.event(.leftMouseDown, point, flags: press.flags, clicks: press.clicks))
            rig.list.mouseUp(with: try rig.event(.leftMouseUp, point, flags: press.flags, clicks: press.clicks))
            #expect(rig.bench.shownWorkspace == shown, "a \(press.name) press showed \(rig.bench.shownWorkspace ?? "nothing")")
        }
    }

    /// The window's press path gives the row the press, and with it the drags and the release. A press that becomes a
    /// drag lifts the row and shows the workspace of before again (`beginDrag`), and no key moves.
    @Test func aRowPressThatBecomesADragLiftsTheRowAndShowsTheWorkspaceOfBefore() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        let shown = try #require(rig.bench.shownWorkspace)
        let target = try rig.otherWorkspace()
        let point = try rig.point(ofRow: target)
        rig.list.leftButtonIsDown = { true }
        try rig.send(.leftMouseDown, point)
        #expect(rig.bench.shownWorkspace == target, "the press did not show \(target)")
        for dy in [CGFloat(10), 40, 0] { try rig.send(.leftMouseDragged, NSPoint(x: point.x, y: point.y - dy)) }
        #expect(rig.list.drag != nil, "the drags after the press did not reach the row: nothing lifted")
        #expect(rig.bench.shownWorkspace == shown, "the drag left \(rig.bench.shownWorkspace ?? "nothing") shown, not \(shown)")
        rig.list.leftButtonIsDown = { false }
        try rig.send(.leftMouseUp, point)
        #expect(rig.list.press == nil, "the release did not reach the row: its press is still held")
        #expect(rig.keyRequests == 0, "the press, its drags and its release asked for \(rig.keyRequests) key changes")
    }

    /// The rail's mark is the other press that shows a workspace (`SidebarRailView`): the same rule on the window's
    /// path. A press on the shown workspace's mark shows nothing else and keeps the key behaviour it had.
    @Test func aRailMarkPressThatShowsAnotherWorkspaceAsksForNoKeyChange() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        let content = try #require(rig.window.contentView)
        let rail = SidebarRailView()
        rail.frame = NSRect(x: content.bounds.maxX - 12, y: 0, width: 8, height: content.bounds.height)
        content.addSubview(rail)
        defer { rail.removeFromSuperview() }
        rail.bind(rig.bench.controller.sidebar.model)
        rail.layoutSubtreeIfNeeded()
        func mark(_ workspace: String) throws -> NSPoint {
            let tick = try #require(rail.railLayout.ticks.first { $0.mark.target == .workspace(WorkspaceID(workspace)) }, "the rail has no mark for \(workspace)")
            let row = rail.railLayout.row(of: tick, railWidth: rail.bounds.width)
            let point = rail.convert(CGPoint(x: row.midX, y: row.midY), to: nil)
            try #require(content.hitTest(point) === rail, "the press at \(point) does not land on the rail: the rig is wrong")
            return point
        }
        let shown = try #require(rig.bench.shownWorkspace)
        let own = try mark(shown)
        try rig.send(.leftMouseDown, own)
        try rig.send(.leftMouseUp, own)
        #expect(rig.keyRequests == 1, "a press on the shown workspace's mark made \(rig.keyRequests) key requests (want 1)")
        let target = try rig.otherWorkspace()
        let other = try mark(target)
        try rig.send(.leftMouseDown, other)
        #expect(rig.keyRequests == 1, "the mark press asked to make the shell window key before the rail got it: the page loses the key")
        #expect(rig.bench.shownWorkspace == target, "the mark press did not show \(target): the window shows \(rig.bench.shownWorkspace ?? "nothing")")
        try rig.send(.leftMouseUp, other)
        #expect(rig.keyRequests == 1, "the mark's release asked for a key change")
    }
}
