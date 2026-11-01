import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Reviews on #27875: a group drawn as its one row (`SidebarLayout+SoleMember`) has no header row. Left on that row
/// focused the group with no ring and Return opened nothing (the row is now the group's stop); the group editor, which Rename in
/// the row's Group options submenu opens, needed the header's view and opened nothing; and a drop into the group (it
/// opens no gap) lit the header's fill, which nothing drew, so an accepted drop showed no destination; and a drag of the
/// row moved only the workspace, so the group could no longer be reordered; and a drop into a nested such group took its
/// step-in from a header the list does not draw, so the gap and card sat at the list's inset; and opening a focused
/// collapsed such group took its header away, so Down walked on from the active workspace instead of from the group, and
/// Tab and Shift-Tab lost their place in the headers; and the icon picker's anchor, VoiceOver's group state and
/// actions, and focus on a group given a new id all looked for the header row.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarSingleMemberGroupKeysTests {
    static let group = GroupID("g-coord")
    static let coord = WorkspaceID("w-coord")

    static func sidebar() -> (SidebarView, NSWindow) {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let nodes: [CmuxNextSidebar.SidebarNode] = [
            .workspace(SidebarWorkspace(id: WorkspaceID("w-loose"), title: "loose")),
            .group(SidebarGroup(id: group, name: "release-coord", workspaces: [SidebarWorkspace(id: coord, title: "release-coord")])),
        ]
        let model = SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: coord)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        window.contentView?.addSubview(sidebar)
        sidebar.list.groupEditor.ordersFront = false
        sidebar.list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    static func close(_ sidebar: SidebarView, _ window: NSWindow) {
        sidebar.list.groupEditor.hide()
        sidebar.list.groupEditor.bubble?.close()
        window.close()
    }

    /// A drag of the one row lifts its group, as a drag of the header did: the group moves as a whole.
    @Test func aDragOfTheOneRowLiftsItsGroup() throws {
        let (sidebar, window) = Self.sidebar()
        defer { Self.close(sidebar, window) }
        window.orderFrontRegardless()
        let list = sidebar.list
        let one = try #require(list.displayed.row(for: .workspace(Self.coord)))
        let start = NSPoint(x: 80, y: one.y + one.height / 2)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: list.convert(point, to: nil), modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        list.mouseDown(with: try event(.leftMouseDown, start))
        for dy: CGFloat in [-4, -12] { list.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: start.x, y: start.y + dy))) }
        let drag = try #require(list.drag, "the row did not lift")
        #expect(drag.payload == .group(Self.group), "a drag of the one row moved \(drag.payload), not its group")
        #expect(drag.group != nil, "the group drag's plan did not start")
        list.cancelDrag()
    }

    /// Review on #27875 at e456a9a8: a drag of the one row out of the sidebar (onto a pane, to merge the workspace or
    /// place it beside) hands off its workspace, as a drag of the member row did; a group payload would cancel there.
    @Test func aDragOfTheOneRowOutOfTheSidebarHandsOffItsWorkspace() throws {
        let (sidebar, window) = Self.sidebar()
        defer { Self.close(sidebar, window) }
        window.orderFrontRegardless()
        let list = sidebar.list
        var offered: SidebarDragHandoff?
        sidebar.onDragHandoff = { offer in
            offered = offer
            return true
        }
        let one = try #require(list.displayed.row(for: .workspace(Self.coord)))
        let start = NSPoint(x: 80, y: one.y + one.height / 2)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: list.convert(point, to: nil), modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        list.mouseDown(with: try event(.leftMouseDown, start))
        for dy: CGFloat in [-4, -12] { list.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: start.x, y: start.y + dy))) }
        #expect(list.drag?.payload == .group(Self.group), "in the sidebar the one row drags its group")
        list.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: 600, y: start.y)))
        let offer = try #require(offered, "the drag out of the sidebar was not handed off")
        #expect(offer.payload == .workspaces([Self.coord]), "the drag out of the sidebar carried \(offer.payload), not its workspace")
        #expect(offer.workspaceIDs == [Self.coord])
        if list.drag != nil { list.cancelDrag() }
    }

    /// A held drag whose drop goes into the group (the middle band of the one row) lights the one row, as it lit the
    /// header: the drop opens no gap, so the fill is its only mark.
    @Test func aDropIntoTheGroupLightsItsOneRow() throws {
        let (sidebar, window) = Self.sidebar()
        defer { Self.close(sidebar, window) }
        window.orderFrontRegardless()
        let list = sidebar.list
        let loose = try #require(list.displayed.row(for: .workspace(WorkspaceID("w-loose"))))
        let start = NSPoint(x: 80, y: loose.y + loose.height / 2)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: list.convert(point, to: nil), modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        list.mouseDown(with: try event(.leftMouseDown, start))
        for dy: CGFloat in [4, 12] { list.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: start.x, y: start.y + dy))) }
        let drag = try #require(list.drag, "the row did not lift")
        drag.target = .intoGroup(Self.group)
        list.showDragLayout()
        let one = try #require(list.rowViews[.workspace(Self.coord)] as? WorkspaceRowView)
        #expect(one.isDropTarget, "a drop into the group drew no mark on its one row")
        list.syncRowStates()
        #expect(one.isDropTarget, "the row-state sync cleared the one row's drop mark")
        list.cancelDrag()
        #expect((list.rowViews[.workspace(Self.coord)] as? WorkspaceRowView)?.isDropTarget != true, "the drop mark outlived the drag")
    }

    /// A drop into a nested group drawn as its one row: the gap and the lifted card step in to that row's level (its
    /// header's level plus one), as they did under its header, never back to the list's inset.
    @Test func aDropIntoANestedOneRowGroupStepsInToItsMembers() throws {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let parent = SidebarGroup(id: GroupID("g-design"), name: "Design review", workspaces: [SidebarWorkspace(id: WorkspaceID("w-sketch"), title: "Sketches")])
        var child = SidebarGroup(id: GroupID("g-visual"), name: "visual-check", workspaces: [SidebarWorkspace(id: WorkspaceID("w-visual"), title: "visual-check")])
        child.parent = parent.id
        child.depth = 1
        let nodes: [CmuxNextSidebar.SidebarNode] = [.workspace(SidebarWorkspace(id: WorkspaceID("w-loose"), title: "loose")), .group(parent), .group(child)]
        let sidebar = SidebarView(model: SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: nodes)]),
                                  design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        window.contentView?.addSubview(sidebar)
        defer { window.close() }
        window.orderFrontRegardless()
        let list = sidebar.list
        list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        let one = try #require(list.displayed.row(for: .workspace(WorkspaceID("w-visual"))))
        #expect(one.standsForGroup && one.depth == 2, "the nested group draws as its one row, two levels in")
        let loose = try #require(list.displayed.row(for: .workspace(WorkspaceID("w-loose"))))
        let start = NSPoint(x: 80, y: loose.y + loose.height / 2)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: list.convert(point, to: nil), modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        list.mouseDown(with: try event(.leftMouseDown, start))
        for dy: CGFloat in [4, 12] { list.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: start.x, y: start.y + dy))) }
        let drag = try #require(list.drag, "the row did not lift")
        defer { list.cancelDrag() }
        // As a tile dragged in from a block: the list opens a gap and moves no row in (a workspace drag's preview moves
        // the row into the group, which brings its header back), so the group still draws as its one row.
        drag.tileSource = (section: "tiles", item: LayoutItemID("tile"))
        drag.target = .position(DropPosition(section: one.section, group: child.id, index: 1))
        list.showDragLayout()
        #expect(list.displayed.row(for: .group(child.id)) == nil, "the gap brought the nested group's header back")
        let stepIn = list.indent.offset(level: one.depth, width: list.indentWidth)
        #expect(stepIn > 0, "a second-level member steps in")
        #expect(list.dropStepIn(list.displayed) == stepIn, "the gap into the nested one-row group sat at another level")
        list.morphLift(drag, point: NSPoint(x: start.x, y: one.maxY))
        #expect(abs(drag.lift.frame.minX - (list.inset + stepIn)) < 0.5, "the card into the nested one-row group sat at \(drag.lift.frame.minX)")
    }

    /// Active loose A, loose B, then collapsed same-named group G. Tab focuses G; Right opens it (its header gives way
    /// to its one row); Down selects G's member, that row, as Down on its header did, not B (walked on from A).
    @Test func keyboardFocusFollowsAnOpenedGroupIntoItsOneRow() throws {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let nodes: [CmuxNextSidebar.SidebarNode] = [
            .workspace(SidebarWorkspace(id: WorkspaceID("w-a"), title: "A")),
            .workspace(SidebarWorkspace(id: WorkspaceID("w-b"), title: "B")),
            .group(SidebarGroup(id: Self.group, name: "release-coord", isCollapsed: true,
                                workspaces: [SidebarWorkspace(id: Self.coord, title: "release-coord")])),
            .workspace(SidebarWorkspace(id: WorkspaceID("w-c"), title: "C")),
        ]
        let model = SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: WorkspaceID("w-a"))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        window.contentView?.addSubview(sidebar)
        defer { window.close() }
        let list = sidebar.list
        list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        func key(_ characters: String, _ code: UInt16) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            _ = SidebarGroupKeys(list: list).handle(event, flags: [])
            list.reload(animated: false)
        }
        try key("\t", 48)
        #expect(list.focusedGroup == Self.group, "Tab did not focus the collapsed group")
        try key(String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), 124)
        #expect(model.group(Self.group)?.isCollapsed == false, "Right did not open the group")
        #expect(try #require(list.displayed.row(for: .workspace(Self.coord))).standsForGroup)
        try key(String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), 125)
        #expect(model.activeWorkspaceID == Self.coord, "Down went to \(String(describing: model.activeWorkspaceID)), not the opened group's member")
        #expect(list.focusedGroup == nil)
        try key(String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), 125)
        #expect(model.activeWorkspaceID == WorkspaceID("w-c"), "Down from the one row did not go on to the next row")
    }

    @Test func tabGoesOnFromAnOpenedGroupsOneRow() throws {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let before = GroupID("g-before"), after = GroupID("g-after")
        let nodes: [CmuxNextSidebar.SidebarNode] = [
            .group(SidebarGroup(id: before, name: "Before", workspaces: [SidebarWorkspace(id: WorkspaceID("w-p1"), title: "P1"),
                                                                         SidebarWorkspace(id: WorkspaceID("w-p2"), title: "P2")])),
            .workspace(SidebarWorkspace(id: WorkspaceID("w-a"), title: "A")),
            .group(SidebarGroup(id: Self.group, name: "release-coord", isCollapsed: true,
                                workspaces: [SidebarWorkspace(id: Self.coord, title: "release-coord")])),
            .group(SidebarGroup(id: after, name: "After", workspaces: [SidebarWorkspace(id: WorkspaceID("w-q1"), title: "Q1"),
                                                                       SidebarWorkspace(id: WorkspaceID("w-q2"), title: "Q2")])),
        ]
        let model = SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: nodes)], activeWorkspaceID: WorkspaceID("w-a"))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        window.contentView?.addSubview(sidebar)
        defer { window.close() }
        let list = sidebar.list
        list.reload(animated: false)
        sidebar.layoutSubtreeIfNeeded()
        func key(_ characters: String, _ code: UInt16, shift: Bool = false) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            _ = SidebarGroupKeys(list: list).handle(event, flags: shift ? [.shift] : [])
            list.reload(animated: false)
        }
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        try key("\t", 48)
        try key("\t", 48)
        #expect(list.focusedGroup == Self.group, "Tab did not reach the collapsed group")
        try key(right, 124)
        #expect(try #require(list.displayed.row(for: .workspace(Self.coord))).standsForGroup)
        try key("\t", 48)
        #expect(list.focusedGroup == after, "Tab from the opened group's one row went to \(String(describing: list.focusedGroup)), not the next header")

        // Focus back where Right left it: on the opened group, drawn as its one row.
        SidebarGroupKeys(list: list).setFocus(Self.group)
        try key("\t", 48, shift: true)
        #expect(list.focusedGroup == before, "Shift-Tab from the opened group's one row went to \(String(describing: list.focusedGroup)), not the previous header")
    }

    /// The one row is its group's header too: Left on it focuses the group there, the row draws the ring, and Return
    /// opens the group's editor at the row.
    @Test func leftOnTheOneRowFocusesItsGroupThere() throws {
        let (sidebar, window) = Self.sidebar()
        defer { Self.close(sidebar, window) }
        let list = sidebar.list
        #expect(try #require(list.displayed.row(for: .workspace(Self.coord))).standsForGroup)
        func key(_ characters: String, _ code: UInt16) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                      isARepeat: false, keyCode: code))
            _ = SidebarGroupKeys(list: list).handle(event, flags: [])
            list.reload(animated: false)
        }
        try key(String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), 123)
        #expect(list.focusedGroup == Self.group, "Left on the one row did not focus its group")
        #expect((list.rowViews[.workspace(Self.coord)] as? WorkspaceRowView)?.isKeyboardFocused == true, "the one row drew no focus ring")
        try key("\r", 36)
        #expect(list.groupEditor.shownGroup == Self.group, "Return on the focused group opened no editor at its one row")
    }

    /// The icon picker anchors a group's popover at its row (`groupRowFrameOnScreen`): for a group drawn as its one
    /// row, that row, not nothing (the picker then fell back to the window's center).
    @Test func theGroupsRowOnScreenIsItsOneRow() throws {
        let (sidebar, window) = Self.sidebar()
        defer { Self.close(sidebar, window) }
        let list = sidebar.list
        let one = try #require(list.displayed.row(for: .workspace(Self.coord)))
        let expected = window.convertToScreen(list.convert(list.frame(for: one), to: nil))
        let frame = try #require(sidebar.groupRowFrameOnScreen(for: Self.group), "a group drawn as its one row has no row on screen")
        #expect(frame == expected)
        #expect(list.hoverCardAnchor(forGroup: Self.group) == expected, "the group's hover card has no anchor at its one row")
    }

    /// VoiceOver on the one row reaches its group as on the header: the expanded state, the editor, the group's menu,
    /// New Workspace in Group and the fold, beside the workspace's own actions.
    @Test func theOneRowCarriesItsGroupsAccessibility() throws {
        let (sidebar, window) = Self.sidebar()
        defer { Self.close(sidebar, window) }
        let list = sidebar.list
        list.onGroupEditorItem = { _, _ in }
        list.reload(animated: false)
        let view = try #require(list.rowViews[.workspace(Self.coord)] as? WorkspaceRowView)
        let names = Set((view.accessibilityCustomActions() ?? []).map(\.name))
        for name in [GroupEditorStrings.editor, GroupEditorStrings.moreActions, GroupEditorStrings.newWorkspace, GroupEditorStrings.collapse] {
            #expect(names.contains(name), "the one row offers VoiceOver no \(name)")
        }
        #expect(view.isAccessibilityExpanded(), "the one row does not say its group is open")
        let edit = try #require(view.accessibilityCustomActions()?.first { $0.name == GroupEditorStrings.editor })
        _ = edit.handler?()
        #expect(list.groupEditor.shownGroup == Self.group, "the one row's editor action opened no editor")
    }

    /// A group the store gives a new id keeps keyboard focus under the new id when it draws as its one row (no header
    /// view moves, so the header's repair never ran).
    @Test func focusFollowsAOneRowGroupGivenANewID() throws {
        let (sidebar, window) = Self.sidebar()
        defer { Self.close(sidebar, window) }
        let list = sidebar.list
        SidebarGroupKeys(list: list).setFocus(Self.group)
        let renamed = GroupID("g-coord-daemon")
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        sidebar.model.setSections([CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID("w-loose"), title: "loose")),
            .group(SidebarGroup(id: renamed, name: "release-coord", workspaces: [SidebarWorkspace(id: Self.coord, title: "release-coord")])),
        ])])
        list.reload(animated: false)
        #expect(list.displayed.row(for: .workspace(Self.coord))?.standsForGroup == true)
        #expect(list.focusedGroup == renamed, "focus stayed on \(String(describing: list.focusedGroup)), a group id the list no longer has")
    }

    @Test func theGroupEditorOpensAtTheOneRow() throws {
        let (sidebar, window) = Self.sidebar()
        defer { Self.close(sidebar, window) }
        sidebar.beginRename(group: Self.group)
        #expect(sidebar.list.groupEditor.shownGroup == Self.group, "Rename Group opened no editor for a group drawn as its one row")
    }
}
