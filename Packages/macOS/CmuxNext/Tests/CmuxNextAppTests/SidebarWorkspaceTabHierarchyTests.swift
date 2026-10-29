import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The disclosed tab rows read as children of their workspace, at every sidebar density and width.
/// The workspace remains the root row: tabs use a stronger inset and quieter secondary typography,
/// while focused and unread tabs keep the primary ink and existing focus fill.
@MainActor @Suite(.serialized) struct SidebarWorkspaceTabHierarchyTests {
    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        var density: SidebarDensity
        var minimal: SidebarMinimalMode
        var width: CGFloat
        var testDescription: String { "\(density.rawValue)/minimal-\(minimal.rawValue)/\(Int(width))pt" }
    }

    nonisolated static let cases: [Case] = SidebarDensity.allCases.flatMap { density in
        [SidebarMinimalMode.off, .both].flatMap { minimal in
            [200, 260].map { Case(density: density, minimal: minimal, width: CGFloat($0)) }
        }
    }

    static let loose = WorkspaceID("tab-loose")
    static let grouped = WorkspaceID("tab-grouped")
    static let nested = WorkspaceID("tab-nested")
    static let group = GroupID("tab-group")
    static let subgroup = GroupID("tab-subgroup")

    private static let favicon: CGImage = {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }()

    private static func workspace(_ id: WorkspaceID, _ title: String, tabs: [SidebarTab], focused: TabID? = nil) -> SidebarWorkspace {
        var workspace = SidebarWorkspace(id: id, title: title)
        workspace.tabs = tabs
        workspace.focusedTab = focused
        return workspace
    }

    static func sections() -> [SidebarSection] {
        let looseTab = SidebarTab(id: TabID("loose-tab"), title: "shell")
        let groupedTab = SidebarTab(id: TabID("grouped-tab"), title: "browser", isUnread: true,
                                     favicon: SidebarFavicon(favicon))
        let nestedTab = SidebarTab(id: TabID("nested-tab"), title: "agent", kind: .agentChat, brand: "claude")
        let looseWorkspace = workspace(loose, "Loose workspace", tabs: [looseTab], focused: looseTab.id)
        let groupedWorkspace = workspace(grouped, "Grouped workspace", tabs: [groupedTab])
        let nestedWorkspace = workspace(nested, "Nested workspace", tabs: [nestedTab])
        var child = SidebarGroup(id: subgroup, name: "Child", color: .yellow, workspaces: [nestedWorkspace])
        child.parent = group
        return [SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(looseWorkspace),
            .group(SidebarGroup(id: group, name: "Parent", color: .blue, workspaces: [groupedWorkspace])),
            .group(child),
        ])]
    }

    static func list(width: CGFloat) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        window.contentView = root
        let model = SidebarModel(sections: sections())
        model.showWorkspaceTabs = true
        let list = SidebarListView(model: model)
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return (list, window)
    }

    static func workspaceRow(_ list: SidebarListView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(list.rowViews[.workspace(id)] as? WorkspaceRowView, "workspace \(id.rawValue) has no row")
    }

    static func tabRow(_ list: SidebarListView, _ workspace: WorkspaceID, _ tab: TabID) throws -> SidebarTabRowView {
        try #require(list.rowViews[.tab(workspace, tab)] as? SidebarTabRowView, "tab \(tab.rawValue) has no row")
    }

    static func listX(_ list: SidebarListView, _ view: NSView, _ x: CGFloat) -> CGFloat {
        list.convert(NSPoint(x: x, y: 0), from: view).x
    }

    @Test(arguments: cases)
    func disclosedTabsReadAsChildrenAcrossParents(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal) {
            let (list, window) = Self.list(width: c.width)
            defer { window.close() }
            let loose = try Self.workspaceRow(list, Self.loose)
            let grouped = try Self.workspaceRow(list, Self.grouped)
            let nested = try Self.workspaceRow(list, Self.nested)
            let looseTab = try Self.tabRow(list, Self.loose, TabID("loose-tab"))
            let groupedTab = try Self.tabRow(list, Self.grouped, TabID("grouped-tab"))
            let nestedTab = try Self.tabRow(list, Self.nested, TabID("nested-tab"))

            for (workspace, tab) in [(loose, looseTab), (grouped, groupedTab), (nested, nestedTab)] {
                let workspaceX = Self.listX(list, workspace, workspace.titleFrame.minX)
                let tabX = Self.listX(list, tab, tab.titleFrame.minX)
                #expect(tabX - workspaceX >= Metrics.space4,
                        "\(c.testDescription): tab \(tab.key) is only \(tabX - workspaceX)pt inside its workspace")
                #expect(tab.titleFont.pointSize < workspace.titleFont.pointSize,
                        "\(c.testDescription): child typography is not quieter")
            }

            // Favicon rows keep the same child column; their title follows the favicon within that column.
            #expect(groupedTab.debugIcon == "favicon", "\(c.testDescription): favicon tab lost its favicon")

            // Workspace siblings and the shared trailing column retain their established alignment.
            let workspaceXs = [loose, grouped, nested].map { id in
                (try? Self.workspaceRow(list, id)).map { Self.listX(list, $0, $0.titleFrame.minX) }
            }
            #expect(workspaceXs.compactMap { $0 }.count == 3, "\(c.testDescription): workspace siblings disappeared")
            let trailing = list.bounds.width - list.inset - SidebarStyle.rowTrailingTrim
            for row in list.displayed.rows where row.key == .workspace(Self.loose) || row.key == .workspace(Self.grouped) || row.key == .workspace(Self.nested) {
                #expect(list.frame(for: row).maxX == trailing, "\(c.testDescription): workspace trailing column moved")
            }
        }
    }

    @Test
    func focusedAndUnreadTabsKeepPrimaryInkAndRowsReuseHierarchyGeometry() throws {
        let (list, window) = Self.list(width: 260)
        defer { window.close() }
        let focused = try Self.tabRow(list, Self.loose, TabID("loose-tab"))
        let unread = try Self.tabRow(list, Self.grouped, TabID("grouped-tab"))
        #expect(focused.isFocusedTab)
        #expect(unread.debugIcon == "favicon")
        #expect(focused.titleFrame.minX > 0 && unread.titleFrame.minX > 0)

        let before = focused.titleFrame
        focused.prepareForReuse(key: .tab(Self.nested, TabID("nested-tab")))
        #expect(focused.titleFrame == before, "reuse changed the disclosed child geometry before configure")
    }
}
