import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-17 (screenshot 1.55.02 AM): "chief workspaces group missing left rail". The host makes
/// "Chief's workspaces" with no color (`workspace_group.create` with no `color`, optchat-chief workspaces.rs), and a
/// group with no color drew its block (`sidebar.noColorGroup`) with no rail, its line color fully clear ("a line nobody
/// sees"); every colored group beside it drew one. Every open group draws one rail by one rule: the same x, top, width
/// and bottom as a colored group's over the same rows, in a neutral color when the group has none.
@MainActor @Suite(.serialized, .closesItsWindows) struct ChiefGroupRailTests {
    static let chief = GroupID("g-chief")
    static let agents = GroupID("g-agents")
    static let chiefMembers = ["Browser j/k scroll feel", "DEBUG launch assertion", "cmux Performance Lead"].map { WorkspaceID("c-" + $0) }
    static let agentMembers = ["one", "two", "three"].map { WorkspaceID("a-" + $0) }

    /// "Chief's workspaces" (no color, as the host makes it) over "Chief agents" (purple, as the user made it), both
    /// open with three members each.
    static func sidebar() -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let host = SidebarGroup(id: chief, name: "Chief's workspaces", custom: GroupTint.noneWire,
                                workspaces: chiefMembers.map { SidebarWorkspace(id: $0, title: $0.rawValue) })
        let user = SidebarGroup(id: agents, name: "Chief agents", color: .purple,
                                workspaces: agentMembers.map { SidebarWorkspace(id: $0, title: $0.rawValue) })
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(SidebarWorkspace(id: WorkspaceID("loose"), title: "scratch")),
                                                            .group(host), .group(user)]),
        ])
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

    /// The rail group `id` draws, in list coordinates, and its paint: a rail line's own frame and fill, or the rail
    /// layer inside a block. Nil when nothing visible runs along the members.
    static func drawnRail(_ sidebar: SidebarView, _ id: GroupID) throws -> (frame: CGRect, fill: NSColor)? {
        let frame = try #require(sidebar.list.groupLineViews.shown[id]?.frame, "\(id) has no line view")
        let view = try #require(GroupPaletteDefaultTests.views(GroupLineView.self, in: sidebar).first { $0.frame == frame })
        view.updateLayer()
        view.layout()
        // A block's rail is any visible shape layer inside the block other than the block's own fill.
        let shapes = (view.layer?.sublayers ?? []).flatMap { [$0] + ($0.sublayers ?? []) }.compactMap { $0 as? CAShapeLayer }
        for shape in shapes where shape.path != nil && !shape.isHidden && !(shape.superlayer?.isHidden ?? false) {
            guard let fill = shape.fillColor.flatMap(NSColor.init(cgColor:)), fill.alphaComponent > 0.05 else { continue }
            let box = shape.superlayer === view.layer ? shape.frame : (shape.superlayer?.frame ?? shape.frame)
            let local = box.intersection(view.bounds)
            guard local.height > 0, local.width > 0 else { continue }
            return (local.offsetBy(dx: frame.minX, dy: frame.minY), fill)
        }
        return nil
    }

    @Test(arguments: [SidebarNoColorGroupLook.glass, .tray, .lit, .plain])
    func theChiefGroupDrawsTheSameRailAsAColoredGroup(look: SidebarNoColorGroupLook) throws {
        try NoColorGroupBlockTests.withLook(look) {
            let (sidebar, window) = Self.sidebar()
            defer { window.close() }
            let list = sidebar.list
            let colored = try #require(try Self.drawnRail(sidebar, Self.agents), "\(look): the colored group draws no rail")
            let chief = try #require(try Self.drawnRail(sidebar, Self.chief), "\(look): \"Chief's workspaces\" draws no left rail")
            let chiefHeader = try #require(list.rowViews[.group(Self.chief)]).frame
            let agentsHeader = try #require(list.rowViews[.group(Self.agents)]).frame
            let chiefLast = try #require(list.rowViews[.workspace(Self.chiefMembers[2])]).frame
            let agentsLast = try #require(list.rowViews[.workspace(Self.agentMembers[2])]).frame
            #expect(chief.frame.minX == colored.frame.minX, "\(look): rail x \(chief.frame.minX), a colored group's \(colored.frame.minX)")
            #expect(chief.frame.width == colored.frame.width, "\(look): rail width \(chief.frame.width), a colored group's \(colored.frame.width)")
            #expect(chief.frame.minY - chiefHeader.maxY == colored.frame.minY - agentsHeader.maxY,
                    "\(look): the rail starts \(chief.frame.minY - chiefHeader.maxY) pt under the header, a colored group's \(colored.frame.minY - agentsHeader.maxY)")
            #expect(chief.frame.maxY == chiefLast.maxY && colored.frame.maxY == agentsLast.maxY, "\(look): each rail ends at its last member")
        }
    }

    /// The neutral rail is the palette's grey, never the sidebar's background.
    @Test func theNoColorRailIsTheNeutralGrey() {
        #expect(GroupTint.none.railTint == .palette(.grey))
        #expect(GroupTint.palette(.purple).railTint == .palette(.purple))
    }

    /// A collapsed group with no color keeps its header block alone: no rail under a folded header.
    @Test func aFoldedChiefGroupDrawsNoRail() {
        let id = GroupID("g-fold")
        func row(_ key: SidebarRowKey, _ y: CGFloat, collapsed: Bool = false) -> SidebarRow {
            SidebarRow(key: key, y: y, height: 24, section: .pinned, group: id, siblingIndex: 0, parentIndex: nil,
                       isLastInGroup: false, isCollapsed: collapsed, childCount: 0, groupColor: nil)
        }
        let group = SidebarGroup(id: id, name: "Chief's workspaces", custom: GroupTint.noneWire, workspaces: [])
        let line = SidebarGroupLine.lines([row(.group(id), 0, collapsed: true)], colors: [id: group], blocks: true) {
            CGRect(x: 8, y: $0.y, width: 200, height: $0.height)
        }.first
        #expect(line?.isBlock == true)
        #expect(line?.rail == nil)
    }
}
