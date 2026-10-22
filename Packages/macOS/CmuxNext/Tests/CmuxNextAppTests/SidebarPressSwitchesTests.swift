import AppKit
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-21: "switching workspaces is very slow ... on mousedown, instantly switch". Leo 2026-10-21 (#23977):
/// "RIGHT CLICKING OR MOUSE DOWN DRAGGING ON A WORKSPACE SHOULDN'T BE IMMEDIATELY FOCUSING". With Debug Settings
/// `sidebar.multiView` off (the default): a plain press on a workspace row switches to it on mouse-down, once; its
/// release sends nothing more; a press that drags moves the row and puts the workspace shown before back; a
/// right-click or control-click opens the menu and switches to nothing. The list is `SidebarPointerGestureTests`':
/// loose `x`, `y`; group `g1` (`a`, `b`); collapsed group `g2` (`c`, `d`); `x` shown.
@MainActor @Suite(.serialized) struct SidebarPressSwitchesTests {
    typealias G = SidebarPointerGestureTests

    /// The list with the toggle off, and every `.select` the list sends (the App switches workspaces on it).
    static func list() -> (SidebarListView, NSWindow, () -> [String]) {
        let (list, window) = G.list()
        var selects: [String] = []
        let model = list.model
        model.onIntent = { intent in
            if case let .select(id) = intent { selects.append(id.rawValue) }
            model.apply(intent)
        }
        return (list, window, { selects })
    }

    static func withToggleOff<T>(_ body: () throws -> T) rethrows -> T {
        try SidebarMultiViewPressTests.withMultiView(false, body)
    }

    @Test func aRightClickOnAnotherRowOpensItsMenuAndSwitchesToNothing() throws {
        try Self.withToggleOff {
            let (list, window, selects) = Self.list()
            defer { window.close() }
            var targets: [SidebarContextTarget] = []
            list.contextMenuProvider = { target in
                targets.append(target)
                return NSMenu()
            }
            let event = try G.event(list, .rightMouseDown, at: try G.point(list, .workspace(WorkspaceID("y"))))
            #expect(list.menu(for: event) != nil, "no menu for the row")
            guard case let .workspaces(ids)? = targets.last else { Issue.record("menu target: \(targets)"); return }
            #expect(ids == [WorkspaceID("y")], "the menu is not for the clicked row: \(ids)")
            #expect(selects().isEmpty, "the right-click switched: \(selects())")
            #expect(list.model.activeWorkspaceID == WorkspaceID("x"))
            #expect(list.model.selection == [WorkspaceID("x")], "the right-click selected: \(list.model.selection)")
            #expect(G.filledRows(list) == ["x"])
        }
    }

    @Test func aRightClickOnARowOfTheSelectionIsForTheWholeSelection() throws {
        try Self.withToggleOff {
            let (list, window, selects) = Self.list()
            defer { window.close() }
            list.model.toggleSelection(WorkspaceID("y"))
            var targets: [SidebarContextTarget] = []
            list.contextMenuProvider = { target in
                targets.append(target)
                return NSMenu()
            }
            _ = list.menu(for: try G.event(list, .rightMouseDown, at: try G.point(list, .workspace(WorkspaceID("y")))))
            guard case let .workspaces(ids)? = targets.last else { Issue.record("menu target: \(targets)"); return }
            #expect(Set(ids) == [WorkspaceID("x"), WorkspaceID("y")])
            #expect(selects().isEmpty)
            #expect(list.model.activeWorkspaceID == WorkspaceID("x"))
        }
    }

    @Test func aControlClickSwitchesToNothing() throws {
        try Self.withToggleOff {
            let (list, window, selects) = Self.list()
            defer { window.close() }
            let point = try G.point(list, .workspace(WorkspaceID("y")))
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: point, flags: .control))
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: point, flags: .control))
            #expect(selects().isEmpty, "the control-click switched: \(selects())")
            #expect(list.model.activeWorkspaceID == WorkspaceID("x"))
            #expect(list.model.selection == [WorkspaceID("x")])
        }
    }

    @Test func aPressSwitchesOnMouseDownOnce() throws {
        try Self.withToggleOff {
            let (list, window, selects) = Self.list()
            defer { window.close() }
            let point = try G.point(list, .workspace(WorkspaceID("y")))
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: point))
            #expect(selects() == ["y"], "the press did not switch once: \(selects())")
            #expect(list.model.activeWorkspaceID == WorkspaceID("y"))
            #expect(list.model.selection == [WorkspaceID("y")])
            #expect(G.filledRows(list) == ["y"], "the press did not move the fill: \(G.filledRows(list))")
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: point))
            #expect(selects() == ["y"], "the release switched again: \(selects())")
            #expect(G.filledRows(list) == ["y"])
        }
    }

    @Test func aPressOnTheShownRowSendsNothing() throws {
        try Self.withToggleOff {
            let (list, window, selects) = Self.list()
            defer { window.close() }
            let point = try G.point(list, .workspace(WorkspaceID("x")))
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: point))
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: point))
            #expect(selects().isEmpty, "a click on the shown row switched: \(selects())")
        }
    }

    @Test func aPressThatDragsMovesTheRowAndPutsTheShownWorkspaceBack() throws {
        try Self.withToggleOff {
            let (list, window, selects) = Self.list()
            defer { window.close() }
            let start = try G.point(list, .workspace(WorkspaceID("y")))
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: start))
            #expect(list.model.activeWorkspaceID == WorkspaceID("y"), "the press did not switch")
            for dy in [CGFloat(-4), -10, -20, -30, -40] {
                list.mouseDragged(with: try G.event(list, .leftMouseDragged, at: NSPoint(x: start.x, y: start.y + dy)))
            }
            #expect(list.drag != nil, "a 40 pt drag did not lift the row")
            #expect(list.model.activeWorkspaceID == WorkspaceID("x"), "the drag left y shown")
            #expect(list.model.selection == [WorkspaceID("x")], "the drag left the selection: \(list.model.selection)")
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: NSPoint(x: start.x, y: start.y - 40)))
            if let landing = list.landing { list.finishLand(landing, then: nil) }
            #expect(Array(G.ids(list).prefix(2)) == ["y", "x"], "the drop did not move y: \(G.ids(list))")
            #expect(selects() == ["y", "x"], "want the press's switch and the drag's switch back: \(selects())")
            #expect(list.model.activeWorkspaceID == WorkspaceID("x"))
            #expect(list.model.selection == [WorkspaceID("x")])
        }
    }

    @Test func aPressBelowTheDragThresholdStaysAClick() throws {
        try Self.withToggleOff {
            let (list, window, selects) = Self.list()
            defer { window.close() }
            let start = try G.point(list, .workspace(WorkspaceID("y")))
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: start))
            list.mouseDragged(with: try G.event(list, .leftMouseDragged, at: NSPoint(x: start.x + 2, y: start.y - 2)))
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: NSPoint(x: start.x + 2, y: start.y - 2)))
            #expect(list.drag == nil)
            #expect(selects() == ["y"], "jitter under the threshold changed the switch: \(selects())")
            #expect(list.model.activeWorkspaceID == WorkspaceID("y"))
        }
    }

    @Test func aReleaseOverAnotherRowKeepsThePressSwitch() throws {
        try Self.withToggleOff {
            let (list, window, selects) = Self.list()
            defer { window.close() }
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: try G.point(list, .workspace(WorkspaceID("y")))))
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: try G.point(list, .workspace(WorkspaceID("a")))))
            #expect(selects() == ["y"], "the release elsewhere switched again: \(selects())")
            #expect(list.model.activeWorkspaceID == WorkspaceID("y"))
        }
    }
}
