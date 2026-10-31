import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Sol review on #27875: a group drawn as its one row (`SidebarLayout+SoleMember`) has no header row. Left on that row
/// focused the group (a header the list does not draw, so Return opened nothing), and the group editor, which Rename in
/// the row's Group options submenu opens, needed the header's view and opened nothing.
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

    @Test func leftOnTheOneRowFocusesNoHeaderlessGroup() throws {
        let (sidebar, window) = Self.sidebar()
        defer { Self.close(sidebar, window) }
        #expect(try #require(sidebar.list.displayed.row(for: .workspace(Self.coord))).standsForGroup)
        let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                  context: nil, characters: left, charactersIgnoringModifiers: left, isARepeat: false, keyCode: 123))
        _ = SidebarGroupKeys(list: sidebar.list).handle(event, flags: [])
        #expect(sidebar.list.focusedGroup == nil, "Left focused a group the list draws no header for")
    }

    @Test func theGroupEditorOpensAtTheOneRow() throws {
        let (sidebar, window) = Self.sidebar()
        defer { Self.close(sidebar, window) }
        sidebar.beginRename(group: Self.group)
        #expect(sidebar.list.groupEditor.shownGroup == Self.group, "Rename Group opened no editor for a group drawn as its one row")
    }
}
