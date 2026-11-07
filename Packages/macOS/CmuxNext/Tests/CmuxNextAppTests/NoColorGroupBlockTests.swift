import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Leo 2026-11-05, on a workspace group with no color that drew exactly like the ungrouped rows around it: "if you're
/// gonna allow the no color option ... you might as well have it be at least slightly distinguishing from, like,
/// literally depicting it as if it were unhovered", "a differently highlighted, differently refracted, differently
/// transparented thing ... a grouped up thing", and "we're not necessarily into that indentation thing". A group with
/// no color draws one neutral block behind its header and members (`sidebar.noColorGroup`), under the rows' own hover
/// and selection, with no hue and no indent; a colored group keeps its rail (#32198 and #32685 stand: no color is
/// never a hue).
@MainActor @Suite(.serialized, .closesItsWindows) struct NoColorGroupBlockTests {
    static let open = GroupID("g-plain")
    static let folded = GroupID("g-plain-folded")
    static let colored = GroupID("g-blue")
    static let members = [WorkspaceID("p-1"), WorkspaceID("p-2"), WorkspaceID("p-3")]
    static let loose = WorkspaceID("loose")

    static func withLook(_ look: SidebarNoColorGroupLook, _ body: () throws -> Void) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarNoColorGroupLook.tunable.key
        defer { TunableStore.shared.set(key, nil) }
        try #require(TunableStore.shared.set(key, look.tunableValue) == look.tunableValue)
        try body()
    }

    /// An ungrouped row, an open group with no color (its second member selected), a collapsed one, and a blue group.
    static func sidebar() -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let plain = SidebarGroup(id: open, name: "No color", custom: GroupTint.noneWire,
                                 workspaces: members.map { SidebarWorkspace(id: $0, title: $0.rawValue) })
        let shut = SidebarGroup(id: folded, name: "Folded", custom: GroupTint.noneWire, isCollapsed: true,
                                workspaces: [SidebarWorkspace(id: WorkspaceID("f-1"), title: "folded")])
        let blue = SidebarGroup(id: colored, name: "Blue", color: .blue, workspaces: [SidebarWorkspace(id: WorkspaceID("b-1"), title: "b")])
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(SidebarWorkspace(id: loose, title: "scratch")),
                                                            .group(plain), .group(shut), .group(blue)]),
        ], activeWorkspaceID: members[1])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        window.contentView = root
        sidebar.frame = root.bounds
        root.addSubview(sidebar)
        window.orderFrontRegardless()
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return (sidebar, window)
    }

    static func lineView(_ sidebar: SidebarView, _ group: GroupID) throws -> GroupLineView {
        let frame = try #require(sidebar.list.groupLineViews.shown[group]?.frame, "\(group) has no line view")
        return try #require(GroupPaletteDefaultTests.views(GroupLineView.self, in: sidebar).first { $0.frame == frame })
    }

    @Test func untintedGlassIsTheDefault() {
        #expect(SidebarNoColorGroupLook.tunable.defaultValue == .glass)
        #expect(SidebarGroupGlass.tunable.defaultValue != .solid, "a group header is glass, not the opaque bar")
    }

    /// The block runs from the header's top to the last member's bottom at the header's x and width: no indent.
    @Test func anOpenGroupWithNoColorDrawsOneBlockBehindItsHeaderAndMembers() throws {
        try Self.withLook(.glass) {
            let (sidebar, window) = Self.sidebar()
            defer { window.close() }
            let list = sidebar.list
            let header = try #require(list.rowViews[.group(Self.open)]).frame
            let last = try #require(list.rowViews[.workspace(Self.members[2])]).frame
            let first = try #require(list.rowViews[.workspace(Self.members[0])]).frame
            let scratch = try #require(list.rowViews[.workspace(Self.loose)]).frame
            let block = try Self.lineView(sidebar, Self.open)
            #expect(block.isBlock)
            #expect(block.frame == CGRect(x: header.minX, y: header.minY, width: max(header.maxX, last.maxX) - header.minX,
                                          height: last.maxY - header.minY), "block \(block.frame), header \(header), last \(last)")
            #expect(first.minX == scratch.minX, "members keep the ungrouped rows' left edge: no indent")
        }
    }

    @Test func aCollapsedGroupWithNoColorBlocksItsHeader() throws {
        try Self.withLook(.glass) {
            let (sidebar, window) = Self.sidebar()
            defer { window.close() }
            let header = try #require(sidebar.list.rowViews[.group(Self.folded)]).frame
            let block = try Self.lineView(sidebar, Self.folded)
            #expect(block.isBlock)
            #expect(block.frame == header)
        }
    }

    /// Hover and selection are the rows' own fills: the block sits under every row, below the list's decorations.
    @Test func theBlockSitsUnderEveryRow() throws {
        try Self.withLook(.glass) {
            let (sidebar, window) = Self.sidebar()
            defer { window.close() }
            let list = sidebar.list
            let block = try Self.lineView(sidebar, Self.open)
            let index = try #require(list.subviews.firstIndex(of: block))
            let decorations = try #require(list.subviews.firstIndex(of: list.decorations))
            #expect(index < decorations)
            for row in list.rowViews.values {
                #expect(index < (list.subviews.firstIndex(of: row) ?? .max), "a row draws under the block")
            }
        }
    }

    @Test func aColoredGroupKeepsItsRail() throws {
        try Self.withLook(.glass) {
            let (sidebar, window) = Self.sidebar()
            defer { window.close() }
            let rail = try Self.lineView(sidebar, Self.colored)
            #expect(!rail.isBlock)
            #expect(rail.frame.width == SidebarStyle.groupBarWidth)
        }
    }

    @Test func thePlainLookDrawsNothing() throws {
        try Self.withLook(.plain) {
            let (sidebar, window) = Self.sidebar()
            defer { window.close() }
            #expect(sidebar.list.groupLineViews.shown[Self.folded] == nil)
            if let line = sidebar.list.groupLineViews.lines.first(where: { $0.group == Self.open }) {
                #expect(!line.isBlock)
            }
        }
    }

    /// Every look is the shared `group` surface role's veil (`SurfaceRole.group`), no hue, fainter than a hovered row, so
    /// an uncolored group never reads as hovered and a hover over it still shows; the glass look adds the role's rim.
    @Test func everyLookIsTheGroupRolesVeilUnderTheHover() throws {
        for look in [SidebarNoColorGroupLook.tray, .glass, .lit] {
            try Self.withLook(look) {
                for (name, scope) in try GroupPaletteDefaultTests.themes() where name != "wallpaper" {
                    let (sidebar, window) = Self.sidebar()
                    defer { window.close() }
                    scope.root(sidebar)
                    let block = try Self.lineView(sidebar, Self.open)
                    block.updateLayer()
                    let role = FloatingGlassStyle.group.look(isDark: scope.tokens.isDark).veil
                    let fill = try #require(look == .lit
                        ? (block.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first?.colors as? [CGColor])?.last
                        : block.layer?.backgroundColor)
                    let ns = try #require(NSColor(cgColor: fill)?.usingColorSpace(.sRGB))
                    #expect(abs(ns.redComponent - role.white) < 0.01 && abs(ns.blueComponent - role.white) < 0.01, "\(look) \(name): not the role's grey")
                    #expect(abs(ns.alphaComponent - role.alpha) < 0.01, "\(look) \(name): alpha \(ns.alphaComponent), the role's \(role.alpha)")
                    #expect(ns.alphaComponent < 0.9 * SurfaceRole.nearOpaque, "\(look) \(name): glass, never opaque")
                    #expect(block.rim.isHidden == (look != .glass), "\(look) \(name): the rim")
                }
            }
        }
    }

    /// The pane holds a group's trailing Done, Archived and Show more rows (router review F2); the rail of a colored
    /// group still ends at its last member.
    @Test func thePaneRunsToTheGroupsFoldRows() {
        let id = GroupID("g-fold")
        func row(_ key: SidebarRowKey, _ y: CGFloat) -> SidebarRow {
            SidebarRow(key: key, y: y, height: 24, section: .pinned, group: id, siblingIndex: 0, parentIndex: nil,
                       isLastInGroup: false, isCollapsed: false, childCount: 0, groupColor: nil)
        }
        let fold = SidebarDoneFoldID(section: .pinned, group: id)
        let rows = [row(.group(id), 0), row(.workspace(WorkspaceID("m")), 26), row(.doneFold(fold), 52), row(.showMore(fold), 78)]
        let frame: (SidebarRow) -> CGRect = { CGRect(x: 8, y: $0.y, width: 200, height: $0.height) }
        func line(_ group: SidebarGroup) -> SidebarGroupLine? {
            SidebarGroupLine.lines(rows, colors: [id: group], blocks: true, frame: frame).first { $0.group == id }
        }
        let pane = line(SidebarGroup(id: id, name: "plain", custom: GroupTint.noneWire, workspaces: []))
        #expect(pane?.isBlock == true)
        #expect(pane?.frame.maxY == 102, "the pane ends at \(String(describing: pane?.frame.maxY)), the Show more row at 102")
        let rail = line(SidebarGroup(id: id, name: "blue", color: .blue, workspaces: []))
        #expect(rail?.isBlock == false)
        #expect(rail?.frame.maxY == 50, "the rail still ends at the last member")
    }

    /// Under Reduce Transparency the pane is the role's opaque fallback: no rim, a hairline.
    @Test func reduceTransparencyDrawsTheOpaqueFallback() throws {
        ReduceTransparency.shared.override = true
        defer { ReduceTransparency.shared.override = nil }
        try Self.withLook(.glass) {
            let (sidebar, window) = Self.sidebar()
            defer { window.close() }
            let block = try Self.lineView(sidebar, Self.open)
            block.updateLayer()
            #expect(block.rim.isHidden)
            #expect(NSColor(cgColor: try #require(block.layer?.backgroundColor))?.alphaComponent == 1)
            #expect((block.layer?.borderWidth ?? 0) > 0)
        }
    }
}
