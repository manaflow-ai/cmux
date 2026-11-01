import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-10-20 (nightly), the cmux NEXT sidebar's pointer bugs, through the list's own mouse events:
/// - a plain click with a few points of trackpad jitter started a drag (a workspace row lifted, a group header lifted
///   with all its members instead of folding);
/// - a press on one row of a multi-selection released over the next row kept the whole selection filled, and the next
///   drag lifted every selected row out of its group;
/// - a drag whose release never reached the list (the app or window lost focus mid-drag) stayed alive: its rows hidden,
///   a drop-target row in the selection fill, and the next press dropped it somewhere;
/// - an external drag's spring-load opened a collapsed group for good.
/// The list: loose `x`, `y`; group `g1` (`a`, `b`); collapsed group `g2` (`c`, `d`).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarPointerGestureTests {
    static func list() -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let ws = { (id: String) in SidebarWorkspace(id: WorkspaceID(id), title: id) }
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(ws("x")),
                .workspace(ws("y")),
                .group(SidebarGroup(id: GroupID("g1"), name: "One", color: .purple, workspaces: [ws("a"), ws("b")])),
                .group(SidebarGroup(id: GroupID("g2"), name: "Two", color: .green, isCollapsed: true, workspaces: [ws("c"), ws("d")])),
            ]),
        ], activeWorkspaceID: WorkspaceID("x"))
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 240, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        return (list, window)
    }

    /// The centre of row `key` (list coordinates), offset by `dy`.
    static func point(_ list: SidebarListView, _ key: SidebarRowKey, dy: CGFloat = 0) throws -> NSPoint {
        let row = try #require(list.displayed.row(for: key), "no row \(key)")
        return NSPoint(x: 80, y: row.y + row.height / 2 + dy)
    }

    static func event(_ list: SidebarListView, _ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags = [],
                      clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: list.convert(point, to: nil), modifierFlags: flags,
                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: list.window?.windowNumber ?? 0,
                                        context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1))
    }

    /// Presses at `start`, moves through `moves` (offsets from `start`), and releases at the last one unless `release` is false.
    static func press(_ list: SidebarListView, at start: NSPoint, moves: [CGVector], release: Bool = true, flags: NSEvent.ModifierFlags = []) throws {
        list.mouseDown(with: try event(list, .leftMouseDown, at: start, flags: flags))
        var last = start
        for move in moves {
            last = NSPoint(x: start.x + move.dx, y: start.y + move.dy)
            list.mouseDragged(with: try event(list, .leftMouseDragged, at: last, flags: flags))
        }
        if release { list.mouseUp(with: try event(list, .leftMouseUp, at: last, flags: flags)) }
    }

    static func ids(_ list: SidebarListView) -> [String] {
        list.model.sections.flatMap(\.nodes).flatMap { node -> [String] in
            switch node {
            case let .workspace(ws): [ws.id.rawValue]
            case let .group(group): ["[" + group.id.rawValue] + group.workspaces.map(\.id.rawValue) + ["]"]
            case .item: []
            }
        }
    }

    /// The realized workspace rows that draw a selection-colored fill (selected, multi-selected or drop target).
    static func filledRows(_ list: SidebarListView) -> Set<String> {
        Set(list.rowViews.compactMap { key, view -> String? in
            guard case let .workspace(id) = key, let row = view as? WorkspaceRowView,
                  row.isSelected || row.isSecondarySelected || row.isDropTarget else { return nil }
            return id.rawValue
        })
    }

    // MARK: - A click is a click

    @Test func aClickWithAFewPointsOfJitterSelectsAndLiftsNothing() throws {
        let (list, window) = Self.list()
        defer { window.close() }
        let order = Self.ids(list)
        let start = try Self.point(list, .workspace(WorkspaceID("a")))
        list.mouseDown(with: try Self.event(list, .leftMouseDown, at: start))
        for move in [CGVector(dx: 2, dy: 1), CGVector(dx: 3, dy: 3), CGVector(dx: 4, dy: 3)] { // 5 pt from the press
            list.mouseDragged(with: try Self.event(list, .leftMouseDragged, at: NSPoint(x: start.x + move.dx, y: start.y + move.dy)))
            #expect(list.drag == nil, "a 5 pt wiggle lifted the row")
        }
        list.mouseUp(with: try Self.event(list, .leftMouseUp, at: NSPoint(x: start.x + 4, y: start.y + 3)))
        #expect(list.drag == nil && list.landing == nil)
        #expect(list.model.activeWorkspaceID == WorkspaceID("a") && list.model.selection == [WorkspaceID("a")])
        #expect(Self.ids(list) == order)
        #expect(list.suppressed.isEmpty)
        #expect(Self.filledRows(list) == ["a"])
    }

    @Test func aGroupHeaderClickWithJitterFoldsTheGroupAndLiftsNoMember() throws {
        let (list, window) = Self.list()
        defer { window.close() }
        let start = try Self.point(list, .group(GroupID("g1")))
        try Self.press(list, at: start, moves: [CGVector(dx: 3, dy: 2), CGVector(dx: 4, dy: 3)])
        #expect(list.drag == nil && list.landing == nil, "a click on a header lifted the group")
        #expect(list.model.group(GroupID("g1"))?.isCollapsed == true, "the click did not fold the group")
        #expect(list.suppressed.isEmpty, "rows still hidden: \(list.suppressed)")
    }

    @Test func aRealDragStillLifts() throws {
        let (list, window) = Self.list()
        defer { window.close() }
        let start = try Self.point(list, .workspace(WorkspaceID("x")))
        try Self.press(list, at: start, moves: [CGVector(dx: 0, dy: 4), CGVector(dx: 0, dy: 12)], release: false)
        #expect(list.drag != nil, "a 12 pt move did not lift the row")
        list.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                         charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        #expect(list.drag == nil)
    }

    // MARK: - The multi-selection's deferred click

    @Test func aPressOnAMultiSelectionReleasedOverTheNextRowSelectsOnlyThePressedRow() throws {
        let (list, window) = Self.list()
        defer { window.close() }
        list.model.click(WorkspaceID("x"))
        list.model.toggleSelection(WorkspaceID("y"))
        list.reload(animated: false)
        #expect(Self.filledRows(list) == ["x", "y"])
        // Down on x (a row of the two-row selection), up over y: no drag event in between.
        list.mouseDown(with: try Self.event(list, .leftMouseDown, at: try Self.point(list, .workspace(WorkspaceID("x")))))
        list.mouseUp(with: try Self.event(list, .leftMouseUp, at: try Self.point(list, .workspace(WorkspaceID("y")))))
        #expect(list.model.selection == [WorkspaceID("x")], "the multi-selection stayed: \(list.model.selection)")
        #expect(Self.filledRows(list) == ["x"], "rows filled: \(Self.filledRows(list))")
    }

    // MARK: - A drag whose release never came

    @Test func focusLossEndsADragWithItsRowsBackAndNoStrayFill() throws {
        let (list, window) = Self.list()
        defer { window.close() }
        let order = Self.ids(list)
        let start = try Self.point(list, .workspace(WorkspaceID("a")))
        try Self.press(list, at: start, moves: [CGVector(dx: 0, dy: 10), CGVector(dx: 0, dy: 30)], release: false)
        #expect(list.drag != nil)
        // What the app resigning active or the window losing key calls (`observeFocusLoss`); a post to the
        // process-global center would reach every other test's observers too.
        list.pointerFocusLost()
        #expect(list.drag == nil, "the drag outlived the app's focus")
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        #expect(Self.ids(list) == order, "a cancelled drag moved rows: \(Self.ids(list))")
        #expect(list.suppressed.isEmpty, "rows still hidden: \(list.suppressed)")
        // The press switched to nothing (Leo 2026-10-21: no focus on mouse-down or drag): only the shown row is filled.
        #expect(Self.filledRows(list) == ["x"], "rows filled: \(Self.filledRows(list))")
        // Its release, when it comes, drops nothing.
        list.mouseUp(with: try Self.event(list, .leftMouseUp, at: NSPoint(x: start.x, y: start.y + 30)))
        #expect(Self.ids(list) == order)
    }

    @Test func aPressWhileAStaleDragIsAliveCancelsItInsteadOfDroppingIt() throws {
        let (list, window) = Self.list()
        defer { window.close() }
        let order = Self.ids(list)
        let start = try Self.point(list, .workspace(WorkspaceID("x")))
        try Self.press(list, at: start, moves: [CGVector(dx: 0, dy: 10), CGVector(dx: 0, dy: 40)], release: false)
        #expect(list.drag != nil)
        // The release went elsewhere; the next press, on b, is a click.
        let b = try Self.point(list, .workspace(WorkspaceID("b")))
        list.mouseDown(with: try Self.event(list, .leftMouseDown, at: b))
        list.mouseUp(with: try Self.event(list, .leftMouseUp, at: b))
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        #expect(list.drag == nil)
        #expect(Self.ids(list) == order, "the stale drag dropped: \(Self.ids(list))")
        #expect(list.model.selection == [WorkspaceID("b")])
        #expect(list.suppressed.isEmpty, "rows still hidden: \(list.suppressed)")
        #expect(Self.filledRows(list) == ["b"], "rows filled: \(Self.filledRows(list))")
    }

    @Test func escapeOnAHeldDragPutsEveryRowBackWhereItWas() throws {
        let (list, window) = Self.list()
        defer { window.close() }
        let order = Self.ids(list)
        let collapsed = list.model.group(GroupID("g2"))?.isCollapsed
        let start = try Self.point(list, .group(GroupID("g1")))
        try Self.press(list, at: start, moves: [CGVector(dx: 0, dy: 10), CGVector(dx: 0, dy: 60)], release: false)
        #expect(list.drag != nil)
        list.keyDown(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                         charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        if let landing = list.landing { list.finishLand(landing, then: nil) }
        list.mouseUp(with: try Self.event(list, .leftMouseUp, at: NSPoint(x: start.x, y: start.y + 60)))
        #expect(Self.ids(list) == order)
        #expect(list.model.group(GroupID("g1"))?.isCollapsed == false, "the drag folded the group it moved")
        #expect(list.model.group(GroupID("g2"))?.isCollapsed == collapsed)
        #expect(list.suppressed.isEmpty, "rows still hidden: \(list.suppressed)")
    }

    // MARK: - Spring-loaded groups close again

    /// A tab dragged in from a pane rests on collapsed `g2`'s header until the spring-load opens it.
    static func springOpen(_ list: SidebarListView) async throws {
        list.springLoadDelay = .zero
        let header = try Self.point(list, .group(GroupID("g2")))
        let hit = list.externalDragMoved(windowPoint: list.convert(header, to: nil), sourceMachine: nil)
        try #require(hit?.0 == .intoGroup(GroupID("g2")), "no group drop on the collapsed header: \(String(describing: hit))")
        await list.external?.springTask?.value
        try #require(list.model.group(GroupID("g2"))?.isCollapsed == false, "the spring-load did not open g2")
    }

    @Test func aGroupTheSpringLoadOpenedClosesWhenTheDragLeaves() async throws {
        let (list, window) = Self.list()
        defer { window.close() }
        try await Self.springOpen(list)
        list.externalDragExited()
        #expect(list.model.group(GroupID("g2"))?.isCollapsed == true, "the drag left g2 open")
    }

    @Test func aGroupTheSpringLoadOpenedStaysOpenForTheDropIntoIt() async throws {
        let (list, window) = Self.list()
        defer { window.close() }
        try await Self.springOpen(list)
        // The tab now goes onto c, inside g2.
        let c = try Self.point(list, .workspace(WorkspaceID("c")))
        _ = list.externalDragMoved(windowPoint: list.convert(c, to: nil), sourceMachine: nil)
        let drop = list.externalDragEnded()
        #expect(drop != nil)
        #expect(list.model.group(GroupID("g2"))?.isCollapsed == false, "the drop into g2 closed it")
    }
}
