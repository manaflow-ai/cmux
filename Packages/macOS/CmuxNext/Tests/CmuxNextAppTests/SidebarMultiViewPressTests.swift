import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-21, item D (Debug Settings `sidebar.multiView`): a press on a workspace row selects nothing, frame by
/// frame, until the button comes up on that row; a hold-then-drag moves the row and never switches to it; every
/// workspace on screen draws a soft fill, the focused one the selection's. The list is `SidebarPointerGestureTests`':
/// loose `x`, `y`; group `g1` (`a`, `b`); collapsed group `g2` (`c`, `d`); `x` shown.
@MainActor @Suite(.serialized) struct SidebarMultiViewPressTests {
    typealias G = SidebarPointerGestureTests

    static func withMultiView<T>(_ on: Bool = true, _ body: () throws -> T) rethrows -> T {
        TunableStore.shared.register(SidebarTunables.all)
        TunableStore.shared.activate(file: nil)
        // Puts back what it found, so a test of the other multi-view suite that runs in this one's await keeps its value.
        let before = TunableStore.shared.override(SidebarTunables.multiView.key)
        TunableStore.shared.set(SidebarTunables.multiView.key, on ? .bool(true) : nil)
        precondition(SidebarTunables.multiView.value == on, "the sidebar.multiView override did not take")
        defer { TunableStore.shared.set(SidebarTunables.multiView.key, before) }
        return try body()
    }

    /// One frame: the list lays out and draws what the event left, as the next display cycle would.
    static func frame(_ list: SidebarListView) {
        list.layoutSubtreeIfNeeded()
        list.displayIfNeeded()
    }

    /// What a frame shows of the selection: the model's selection and shown workspace, and the filled rows.
    static func shown(_ list: SidebarListView) -> String {
        "active=\(list.model.activeWorkspaceID?.rawValue ?? "-") selection=\(list.model.selection.map(\.rawValue).sorted()) "
            + "filled=\(G.filledRows(list).sorted())"
    }

    @Test func aPressChangesNoSelectionInAnyFrameUntilItsRelease() throws {
        try Self.withMultiView {
            let (list, window) = G.list()
            defer { window.close() }
            Self.frame(list)
            let before = Self.shown(list)
            let start = try G.point(list, .workspace(WorkspaceID("y")))
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: start))
            Self.frame(list)
            #expect(Self.shown(list) == before, "frame 0 (mouse-down) selected: \(Self.shown(list))")
            // A held press with trackpad jitter (under the drag threshold), one frame per event.
            for (n, move) in [CGVector(dx: 1, dy: 0), CGVector(dx: 2, dy: 1), CGVector(dx: 3, dy: 2), CGVector(dx: 2, dy: 3)].enumerated() {
                list.mouseDragged(with: try G.event(list, .leftMouseDragged, at: NSPoint(x: start.x + move.dx, y: start.y + move.dy)))
                Self.frame(list)
                #expect(list.drag == nil)
                #expect(Self.shown(list) == before, "frame \(n + 1) of the held press selected: \(Self.shown(list))")
            }
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: NSPoint(x: start.x + 2, y: start.y + 3)))
            Self.frame(list)
            #expect(list.model.activeWorkspaceID == WorkspaceID("y"), "the release did not navigate: \(Self.shown(list))")
            #expect(list.model.selection == [WorkspaceID("y")])
            #expect(G.filledRows(list) == ["y"])
        }
    }

    @Test func aReleaseOverAnotherRowNavigatesNowhere() throws {
        try Self.withMultiView {
            let (list, window) = G.list()
            defer { window.close() }
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: try G.point(list, .workspace(WorkspaceID("y")))))
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: try G.point(list, .workspace(WorkspaceID("a")))))
            Self.frame(list)
            #expect(list.model.activeWorkspaceID == WorkspaceID("x"), "a press released elsewhere navigated: \(Self.shown(list))")
            #expect(G.filledRows(list) == ["x"])
        }
    }

    @Test func aHoldThenDragMovesTheRowAndKeepsTheShownWorkspaceInEveryFrame() throws {
        try Self.withMultiView {
            let (list, window) = G.list()
            defer { window.close() }
            Self.frame(list)
            let start = try G.point(list, .workspace(WorkspaceID("y")))
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: start))
            // y dragged up past x, a frame per event.
            for dy in [CGFloat(-4), -10, -20, -30, -40] {
                list.mouseDragged(with: try G.event(list, .leftMouseDragged, at: NSPoint(x: start.x, y: start.y + dy)))
                Self.frame(list)
                #expect(list.model.activeWorkspaceID == WorkspaceID("x"), "the drag at \(dy) pt switched: \(Self.shown(list))")
                #expect(list.model.selection == [WorkspaceID("x")], "the drag at \(dy) pt selected: \(Self.shown(list))")
            }
            #expect(list.drag != nil, "a 40 pt hold-then-drag did not lift the row")
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: NSPoint(x: start.x, y: start.y - 40)))
            if let landing = list.landing { list.finishLand(landing, then: nil) }
            Self.frame(list)
            #expect(Array(G.ids(list).prefix(2)) == ["y", "x"], "the drop did not move y: \(G.ids(list))")
            #expect(list.model.activeWorkspaceID == WorkspaceID("x"), "the drop switched workspaces: \(Self.shown(list))")
            #expect(list.model.selection == [WorkspaceID("x")])
            #expect(list.suppressed.isEmpty)
        }
    }

    /// With the toggle off (the default) a plain press switches on mouse-down (Lawrence 2026-10-21, workspace switch
    /// lag); a drag puts it back (`SidebarPressDoesNotFocusTests`). Navigate on release is the multi-view prototype's.
    @Test func withTheToggleOffAPressSwitchesOnMouseDown() throws {
        try Self.withMultiView(false) {
            let (list, window) = G.list()
            defer { window.close() }
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: try G.point(list, .workspace(WorkspaceID("y")))))
            #expect(list.model.activeWorkspaceID == WorkspaceID("y"), "the press did not switch: \(Self.shown(list))")
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: try G.point(list, .workspace(WorkspaceID("y")))))
            #expect(list.model.activeWorkspaceID == WorkspaceID("y"))
        }
    }

    // MARK: - Every workspace on screen

    static func onScreenRows(_ list: SidebarListView) -> Set<String> {
        Set(list.rowViews.compactMap { key, view -> String? in
            guard case let .workspace(id) = key, let row = view as? WorkspaceRowView, row.isOnScreen else { return nil }
            return id.rawValue
        })
    }

    @Test func everyWorkspaceOnScreenGetsASoftFillAndTheFocusedOneTheSelections() throws {
        try Self.withMultiView {
            let (list, window) = G.list()
            defer { window.close() }
            list.model.onScreen = [WorkspaceID("x"), WorkspaceID("y"), WorkspaceID("a")]
            list.syncRowStates()
            Self.frame(list)
            #expect(Self.onScreenRows(list) == ["y", "a"], "soft fills: \(Self.onScreenRows(list))")
            let focused = try #require(list.rowViews[.workspace(WorkspaceID("x"))] as? WorkspaceRowView)
            #expect(focused.isSelected && !focused.isOnScreen, "the focused row is not the strong one")
            // A click on another on-screen workspace moves the strong fill; the one it left keeps the soft one.
            try G.press(list, at: try G.point(list, .workspace(WorkspaceID("a"))), moves: [])
            Self.frame(list)
            #expect(list.model.activeWorkspaceID == WorkspaceID("a"))
            #expect(Self.onScreenRows(list) == ["x", "y"], "soft fills after the click: \(Self.onScreenRows(list))")
            // Off screen again: the soft fill goes, a reused row included.
            list.model.onScreen = [WorkspaceID("a")]
            list.syncRowStates()
            #expect(Self.onScreenRows(list).isEmpty)
        }
    }

    @Test func withTheToggleOffNoRowDrawsTheOnScreenFill() throws {
        try Self.withMultiView(false) {
            let (list, window) = G.list()
            defer { window.close() }
            list.model.onScreen = [WorkspaceID("x"), WorkspaceID("y")]
            list.syncRowStates()
            #expect(Self.onScreenRows(list).isEmpty)
        }
    }
}
