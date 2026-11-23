import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import CmuxTheme
import Testing

/// David Beyer's feedback (2026-11-20 call, launch Mon Nov 23): sidebar groups should be plain folders, with all threads
/// in one place. With the default settings a group draws as a folder in a file list: a folder glyph and its name in the
/// theme's primary ink, no band, rim, dot, block or members' line, and its members one indent step in under it, so the
/// tree reads with no chrome. The header stays flush with the loose rows and keeps folding, renaming and taking drops
/// (the row's own fill under the pointer and a drop, as a workspace row's).
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarGroupsAsFoldersTests {
    static let group = GroupID("g-folder")
    static let looseID = WorkspaceID("ws-loose")
    static let memberID = WorkspaceID("ws-member")
    static let otherID = WorkspaceID("ws-other")

    /// A sidebar with one loose workspace and an open group of two, under the default `sidebar.*` settings.
    static func sidebar(tint: GroupTint = .none) -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let folder = SidebarGroup(id: group, name: "Backend", custom: tint.wire, workspaces: [
            SidebarWorkspace(id: memberID, title: "api server"),
            SidebarWorkspace(id: otherID, title: "web app"),
        ])
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(SidebarWorkspace(id: looseID, title: "scratch")), .group(folder)]),
        ], activeWorkspaceID: looseID)
        model.applyListPreferences(SidebarSectionsPreferences())
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        window.contentView = root
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.model.applyListPreferences(SidebarSectionsPreferences())
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return (sidebar, window)
    }

    static func row(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView, "no row for \(id.rawValue)")
    }

    /// The default header in `scope`, as the sidebar configures it from the default settings.
    static func header(_ tint: GroupTint, in scope: ThemeScope, hovered: Bool = false, drop: Bool = false) -> GroupHeaderRowView {
        let id = GroupID("grp_folder")
        let header = GroupHeaderRowView(key: .group(id))
        header.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        scope.root(header)
        let group = CmuxNextSidebar.SidebarGroup(id: id, name: "Backend", custom: tint.wire, workspaces: [])
        let row = SidebarRow(key: .group(id), y: 0, height: 24, section: .pinned, group: id, siblingIndex: 0,
                             parentIndex: nil, isLastInGroup: false, isCollapsed: false, childCount: 2, groupColor: nil)
        let details = GroupHeaderDetails(background: SidebarSectionsPreferences().groupHeaderBackground)
        header.configure(group, row: row, details: details, animated: false)
        header.isHovered = hovered
        header.isDropTarget = drop
        header.layoutSubtreeIfNeeded()
        header.updateLayer()
        return header
    }

    @Test func theDefaultGroupDrawsNoBackground() {
        #expect(!SidebarSectionsPreferences().groupHeaderBackground.drawsBackground,
                "a group's default background is \(SidebarSectionsPreferences().groupHeaderBackground), not a plain folder")
    }

    /// At rest: no fill, rim or dot, a folder glyph before the name, the name in the primary ink, in a dark, a light
    /// and a wallpaper room, for a group with no color and every palette color. Under the pointer and a drop, the row's
    /// own fill, so the folder still says where a click or a drop goes.
    @Test func aFolderHeaderIsAGlyphAndANameInEveryRoom() throws {
        var failures: [String] = []
        let tints = [GroupTint.none] + GroupColor.allCases.map { GroupTint.palette($0) }
        for (name, scope) in try GroupPaletteDefaultTests.themes() {
            let primary = scope.tokens.textPrimary
            for tint in tints {
                let label = "\(name) \(tint.wire)"
                let header = Self.header(tint, in: scope)
                let fill = GroupHeaderAlwaysVisibleTests.rgba(header.pill.backgroundColor)
                if fill.alpha > 0.001 { failures.append("\(label): a fill \(fill)") }
                if !header.rim.isHidden { failures.append("\(label): a rim") }
                if !header.dot.isHidden { failures.append("\(label): a dot") }
                if header.debugFill { failures.append("\(label): a row fill at rest") }
                if header.glyph.isHidden { failures.append("\(label): no folder glyph") }
                if header.glyph.frame.maxX > header.name.frame.minX { failures.append("\(label): the glyph \(header.glyph.frame) is not before the name \(header.name.frame)") }
                let ink = try GroupPaletteDefaultTests.rgb(header.ink?.cgColor)
                if !GroupPaletteDefaultTests.same(ink, primary) { failures.append("\(label): ink \(ink), want the primary \(primary)") }
                if !Self.header(tint, in: scope, hovered: true).debugFill { failures.append("\(label): no fill under the pointer") }
                if !Self.header(tint, in: scope, drop: true).debugFill { failures.append("\(label): no fill under a drop") }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) folder headers off:\n" + failures.joined(separator: "\n")))
    }

    /// No members' line and no block behind a folder's members, colored or not.
    @Test func aFoldersMembersDrawNoLineOrBlock() throws {
        for (name, scope) in try GroupPaletteDefaultTests.themes() {
            for (tint, block) in [(GroupTint.palette(.blue), false), (GroupTint.none, true)] {
                let line = GroupLineView()
                line.frame = NSRect(x: 0, y: 0, width: block ? 240 : 2, height: 48)
                scope.root(line)
                line.color = tint
                line.isBlock = block
                line.background = SidebarSectionsPreferences().groupHeaderBackground
                line.updateLayer()
                #expect(line.railShape.fillColor == nil, "\(name) \(tint.wire): a rail")
                #expect(line.layer?.backgroundColor == nil, "\(name) \(tint.wire): a block")
                #expect(line.rim.isHidden, "\(name) \(tint.wire): a rim")
            }
        }
    }

    /// The tree reads by indent: the folder's header is flush with the loose rows (same frame x and width, its glyph
    /// on their icon column), and its members sit one step (`SidebarStyle.groupGutter`) in, every row ending at the
    /// loose rows' right edge.
    @Test(arguments: [GroupTint.none, GroupTint.palette(.blue)])
    func membersSitOneStepInUnderAFlushHeader(tint: GroupTint) throws {
        let (sidebar, window) = Self.sidebar(tint: tint)
        defer { window.close() }
        let list = sidebar.list
        let loose = try Self.row(sidebar, Self.looseID)
        let header = try #require(list.rowViews[.group(Self.group)] as? GroupHeaderRowView)
        #expect(header.frame.minX == loose.frame.minX, "the header starts at \(header.frame.minX), loose rows at \(loose.frame.minX)")
        #expect(header.frame.maxX == loose.frame.maxX, "the header ends at \(header.frame.maxX), loose rows at \(loose.frame.maxX)")
        #expect(!header.glyph.isHidden, "the header shows no folder glyph")
        for id in [Self.memberID, Self.otherID] {
            let member = try Self.row(sidebar, id)
            let step = member.frame.minX - loose.frame.minX
            #expect(abs(step - SidebarStyle.groupGutter) < 0.5, "\(id.rawValue) sits \(step) pt in, want one step \(SidebarStyle.groupGutter)")
            #expect(member.frame.maxX == loose.frame.maxX, "\(id.rawValue) ends at \(member.frame.maxX), loose rows at \(loose.frame.maxX)")
        }
    }

    /// Folding a folder hides its members and opening it shows them again: every thread stays reachable from the one
    /// list.
    @Test func foldingAFolderHidesAndShowsItsMembers() throws {
        let (sidebar, window) = Self.sidebar()
        defer { window.close() }
        let list = sidebar.list
        #expect(list.displayed.row(for: .workspace(Self.memberID)) != nil, "an open folder hides its member")
        sidebar.model.setGroupCollapsed(Self.group, true)
        list.reload(animated: false)
        #expect(list.displayed.row(for: .workspace(Self.memberID)) == nil, "a folded folder still lists its member")
        #expect(list.displayed.row(for: .group(Self.group)) != nil, "a folded folder hides its own row")
        sidebar.model.setGroupCollapsed(Self.group, false)
        list.reload(animated: false)
        #expect(list.displayed.row(for: .workspace(Self.memberID)) != nil, "an opened folder hides its member")
    }
}
