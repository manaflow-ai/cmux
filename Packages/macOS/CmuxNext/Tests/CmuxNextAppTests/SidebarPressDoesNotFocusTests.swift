import AppKit
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-21: "RIGHT CLICKING OR MOUSE DOWN DRAGGING ON A WORKSPACE SHOULDN'T BE IMMEDIATELY FOCUSING". With
/// Debug Settings `sidebar.multiView` off (the default): a right-click or control-click on a workspace row opens its
/// menu and switches to nothing, a press alone switches to nothing, a press that drags moves the row and switches to
/// nothing, and a click (the release on the pressed row, no drag) switches. The list is `SidebarPointerGestureTests`':
/// loose `x`, `y`; group `g1` (`a`, `b`); collapsed group `g2` (`c`, `d`); `x` shown.
@MainActor @Suite(.serialized) struct SidebarPressDoesNotFocusTests {
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

    @Test func aPressAloneSwitchesToNothing() throws {
        try Self.withToggleOff {
            let (list, window, selects) = Self.list()
            defer { window.close() }
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: try G.point(list, .workspace(WorkspaceID("y")))))
            #expect(selects().isEmpty, "the press switched: \(selects())")
            #expect(list.model.activeWorkspaceID == WorkspaceID("x"))
            #expect(list.model.selection == [WorkspaceID("x")])
            #expect(G.filledRows(list) == ["x"], "the press filled: \(G.filledRows(list))")
            list.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                             windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                             charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        }
    }

    @Test func aPressThatDragsMovesTheRowAndSwitchesToNothing() throws {
        try Self.withToggleOff {
            let (list, window, selects) = Self.list()
            defer { window.close() }
            let start = try G.point(list, .workspace(WorkspaceID("y")))
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: start))
            for dy in [CGFloat(-4), -10, -20, -30, -40] {
                list.mouseDragged(with: try G.event(list, .leftMouseDragged, at: NSPoint(x: start.x, y: start.y + dy)))
                #expect(selects().isEmpty, "the drag at \(dy) pt switched: \(selects())")
            }
            #expect(list.drag != nil, "a 40 pt drag did not lift the row")
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: NSPoint(x: start.x, y: start.y - 40)))
            if let landing = list.landing { list.finishLand(landing, then: nil) }
            #expect(Array(G.ids(list).prefix(2)) == ["y", "x"], "the drop did not move y: \(G.ids(list))")
            #expect(selects().isEmpty, "the drop switched: \(selects())")
            #expect(list.model.activeWorkspaceID == WorkspaceID("x"))
            #expect(list.model.selection == [WorkspaceID("x")])
        }
    }

    @Test func aClickSwitchesOnItsRelease() throws {
        try Self.withToggleOff {
            let (list, window, selects) = Self.list()
            defer { window.close() }
            let point = try G.point(list, .workspace(WorkspaceID("y")))
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: point))
            #expect(selects().isEmpty)
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: point))
            #expect(selects() == ["y"], "the click did not switch once: \(selects())")
            #expect(list.model.activeWorkspaceID == WorkspaceID("y"))
            #expect(list.model.selection == [WorkspaceID("y")])
            #expect(G.filledRows(list) == ["y"])
        }
    }

    @Test func aReleaseOverAnotherRowSwitchesToNothing() throws {
        try Self.withToggleOff {
            let (list, window, selects) = Self.list()
            defer { window.close() }
            list.mouseDown(with: try G.event(list, .leftMouseDown, at: try G.point(list, .workspace(WorkspaceID("y")))))
            list.mouseUp(with: try G.event(list, .leftMouseUp, at: try G.point(list, .workspace(WorkspaceID("a")))))
            #expect(selects().isEmpty, "a press released elsewhere switched: \(selects())")
            #expect(list.model.activeWorkspaceID == WorkspaceID("x"))
        }
    }
}
