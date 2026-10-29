import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The disclosed tab rows read as children of their workspace, at every sidebar density and width.
/// The workspace remains the root row: tabs use a stronger inset and quieter secondary typography,
/// while focused and unread tabs keep the primary ink and existing focus fill.
@MainActor @Suite(.serialized, .enabled(if: !NSScreen.screens.isEmpty, "needs a GUI display host"))
struct SidebarWorkspaceTabHierarchyTests {
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

    private static func favicon() throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return try #require(context.makeImage())
    }

    private static func workspace(_ id: WorkspaceID, _ title: String, tabs: [SidebarTab], focused: TabID? = nil) -> SidebarWorkspace {
        var workspace = SidebarWorkspace(id: id, title: title)
        workspace.tabs = tabs
        workspace.focusedTab = focused
        return workspace
    }

    static func sections() throws -> [SidebarSection] {
        let looseTab = SidebarTab(id: TabID("loose-tab"), title: "shell")
        let groupedTab = SidebarTab(id: TabID("grouped-tab"), title: "browser", isUnread: true,
                                     favicon: SidebarFavicon(try Self.favicon()))
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

    static func list(width: CGFloat) throws -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        window.contentView = root
        let model = SidebarModel(sections: try sections())
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

    static func tabTitle(_ row: SidebarTabRowView, _ text: String) throws -> ChromeLabel {
        let labels = ([row] + row.subviews.flatMap { [$0] + $0.subviews }).compactMap { $0 as? ChromeLabel }
        return try #require(labels.first { $0.stringValue == text }, "tab title \(text) has no ChromeLabel")
    }

    static func sidebarRow(_ list: SidebarListView, _ key: SidebarRowKey) throws -> SidebarRow {
        try #require(list.displayed.rows.first { $0.key == key }, "row \(key) has no layout entry")
    }

    static func listX(_ list: SidebarListView, _ view: NSView, _ x: CGFloat) -> CGFloat {
        list.convert(NSPoint(x: x, y: 0), from: view).x
    }

    @Test(arguments: cases)
    func disclosedTabsReadAsChildrenAcrossParents(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal) {
            let (list, window) = try Self.list(width: c.width)
            defer { window.close() }
            let loose = try Self.workspaceRow(list, Self.loose)
            let grouped = try Self.workspaceRow(list, Self.grouped)
            let nested = try Self.workspaceRow(list, Self.nested)
            let looseTab = try Self.tabRow(list, Self.loose, TabID("loose-tab"))
            let groupedTab = try Self.tabRow(list, Self.grouped, TabID("grouped-tab"))
            let nestedTab = try Self.tabRow(list, Self.nested, TabID("nested-tab"))

            for (workspace, tab, text) in [(loose, looseTab, "shell"), (grouped, groupedTab, "browser"), (nested, nestedTab, "agent")] {
                let tabTitle = try Self.tabTitle(tab, text)
                let workspaceX = Self.listX(list, workspace, workspace.title.frame.minX)
                let tabX = Self.listX(list, tab, tabTitle.frame.minX)
                #expect(tabX - workspaceX >= Metrics.space4,
                        "\(c.testDescription): tab \(tab.key) is only \(tabX - workspaceX)pt inside its workspace")
                #expect(tabTitle.font?.pointSize ?? 0 < workspace.title.font.pointSize,
                        "\(c.testDescription): child typography is not quieter")
            }

            // Favicon rows keep the same child column; their title follows the favicon within that column.
            #expect(groupedTab.debugIcon == "favicon", "\(c.testDescription): favicon tab lost its favicon")

            // Workspace siblings and the shared trailing column retain their established alignment.
            let workspaceXs = [loose, grouped, nested].map { (workspace: WorkspaceRowView) in Self.listX(list, workspace, workspace.titleFrame.minX) }
            #expect(abs(workspaceXs[1] - workspaceXs[0]) < 0.5,
                    "\(c.testDescription): grouped workspace left its shared workspace column")
            #expect(workspaceXs[2] > workspaceXs[1],
                    "\(c.testDescription): nested workspace lost its lineage offset")
            let trailing = list.bounds.width - list.inset - SidebarStyle.rowTrailingTrim
            for row in list.displayed.rows where row.key == .workspace(Self.loose) || row.key == .workspace(Self.grouped) || row.key == .workspace(Self.nested) {
                #expect(list.frame(for: row).maxX == trailing, "\(c.testDescription): workspace trailing column moved")
            }
        }
    }

    @Test
    func focusedAndUnreadTabsKeepPrimaryInkAndRowsReuseHierarchyGeometry() throws {
        let (list, window) = try Self.list(width: 260)
        defer { window.close() }
        let focused = try Self.tabRow(list, Self.loose, TabID("loose-tab"))
        let unread = try Self.tabRow(list, Self.grouped, TabID("grouped-tab"))
        let plain = try Self.tabRow(list, Self.nested, TabID("nested-tab"))
        let looseTab = try #require(list.tabs[TabID("loose-tab")])
        let groupedTab = try #require(list.tabs[TabID("grouped-tab")])
        let nestedTab = try #require(list.tabs[TabID("nested-tab")])
        let looseRow = try Self.sidebarRow(list, .tab(Self.loose, looseTab.id))
        let groupedRow = try Self.sidebarRow(list, .tab(Self.grouped, groupedTab.id))
        let nestedRow = try Self.sidebarRow(list, .tab(Self.nested, nestedTab.id))
        focused.updateLayer()
        unread.updateLayer()
        plain.updateLayer()
        let focusedTitle = try Self.tabTitle(focused, "shell")
        let unreadTitle = try Self.tabTitle(unread, "browser")
        let plainTitle = try Self.tabTitle(plain, "agent")
        #expect(focused.isFocusedTab)
        #expect(unread.debugIcon == "favicon")
        #expect(focusedTitle.frame.minX > 0 && unreadTitle.frame.minX > 0)
        #expect(focusedTitle.textColor == focused.performWithTheme { Palette.textPrimary },
                "focused child lost primary ink")
        #expect(unreadTitle.textColor == unread.performWithTheme { Palette.textPrimary },
                "unread child lost primary ink")
        #expect(plainTitle.textColor == plain.performWithTheme { Palette.textSecondary },
                "plain child did not recede to secondary ink")

        var readTab = groupedTab
        readTab.isUnread = false
        unread.configure(readTab, row: groupedRow, focused: false)
        unread.layoutSubtreeIfNeeded()
        unread.updateLayer()
        #expect(try Self.tabTitle(unread, "browser").textColor == unread.performWithTheme { Palette.textSecondary },
                "read transition did not quiet the tab")
        unread.configure(groupedTab, row: groupedRow, focused: false)
        unread.layoutSubtreeIfNeeded()
        unread.updateLayer()
        #expect(try Self.tabTitle(unread, "browser").textColor == unread.performWithTheme { Palette.textPrimary },
                "unread transition did not restore primary ink")

        focused.configure(looseTab, row: looseRow, focused: false)
        focused.layoutSubtreeIfNeeded()
        focused.updateLayer()
        #expect(try Self.tabTitle(focused, "shell").textColor == focused.performWithTheme { Palette.textSecondary },
                "focus transition did not quiet the tab")
        focused.configure(looseTab, row: looseRow, focused: true)
        focused.layoutSubtreeIfNeeded()
        focused.updateLayer()
        #expect(try Self.tabTitle(focused, "shell").textColor == focused.performWithTheme { Palette.textPrimary },
                "focus transition did not restore primary ink")

        let before = try Self.tabTitle(focused, "shell").frame
        focused.prepareForReuse(key: .tab(Self.nested, TabID("nested-tab")))
        #expect(try Self.tabTitle(focused, "shell").frame == before, "reuse changed the disclosed child geometry before configure")
        focused.configure(nestedTab, row: nestedRow, focused: false)
        focused.layoutSubtreeIfNeeded()
        focused.updateLayer()
        #expect(try Self.tabTitle(focused, "agent").textColor == focused.performWithTheme { Palette.textSecondary },
                "reused plain child did not recede to secondary ink")
    }
}
