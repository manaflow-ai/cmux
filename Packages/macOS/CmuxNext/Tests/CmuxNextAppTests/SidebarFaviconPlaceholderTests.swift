import AppKit
@testable import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence default "a site with no favicon gets a placeholder (a neutral globe glyph in the same icon slot)": a browser
/// workspace whose page has no favicon (none, or not loaded yet) draws a glyph in the icon slot, so its title starts
/// where a favicon row's does. The rows are mapped from real daemon workspaces (`SidebarMapping.row`, the page face as
/// `AppServices.sidebarPageFace` gives it) and drawn by the real list at every density and text size.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarFaviconPlaceholderTests {
    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        var density: SidebarDensity
        var textSize: SidebarTextSize
        var testDescription: String { "\(density.rawValue)/text-\(textSize.rawValue)" }
    }

    nonisolated static let cases: [Case] = SidebarDensity.allCases.flatMap { density in
        SidebarTextSize.allCases.map { Case(density: density, textSize: $0) }
    }

    static let favicon: SidebarFavicon = SidebarFavicon(SidebarFaviconLegibilityTests.colourful())

    /// One browser workspace on `url`, mapped to its sidebar row with the page's favicon when `hasFavicon`.
    static func row(id: WorkspaceHandle, url: String, hasFavicon: Bool) throws -> SidebarWorkspace {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, kind: .browser, title: "Page", url: url)])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: id, key: nil, name: "workspace-page", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        return SidebarMapping.shared.row(workspace, machine: .local, pageFace: { _, tab, _ in
            .init(title: tab.title, favicon: tab.kind == .browser && hasFavicon ? favicon : nil)
        })
    }

    /// The list of a favicon row and a no-favicon row in a window, laid out.
    static func list(_ rows: [SidebarWorkspace]) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: rows.map { .workspace($0) })])
        let list = SidebarListView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        list.rowViews.values.forEach { $0.needsLayout = true; $0.layoutSubtreeIfNeeded() }
        return (list, window)
    }

    /// With no favicon the row still draws a glyph in the icon slot, and its title starts at the favicon row's title x.
    @Test(arguments: cases)
    func aSiteWithNoFaviconKeepsTheIconSlot(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, .off, textSize: c.textSize) {
            let withIcon = try Self.row(id: 1, url: "https://github.com/manaflow-ai/cmux", hasFavicon: true)
            let without = try Self.row(id: 2, url: "https://example.com/docs", hasFavicon: false)
            #expect(withIcon.icon == .favicon(Self.favicon), "\(c.testDescription): the favicon row lost its favicon")
            let (list, window) = Self.list([withIcon, without])
            defer { window.close() }
            let faviconRow = try HomePinnedRowAlignmentTests.row(list, withIcon.id)
            let placeholderRow = try HomePinnedRowAlignmentTests.row(list, without.id)
            let faviconX = SidebarLeadingEdgeTests.x(list, faviconRow.title.frame.minX, in: faviconRow)
            let placeholderX = SidebarLeadingEdgeTests.x(list, placeholderRow.title.frame.minX, in: placeholderRow)
            #expect(abs(placeholderX - faviconX) <= HomePinnedRowAlignmentTests.tolerance,
                    "\(c.testDescription): the no-favicon title starts at \(placeholderX), the favicon row's at \(faviconX)")
            let slot = placeholderRow.icon
            #expect(!slot.isHidden && slot.frame.width > 0, "\(c.testDescription): the no-favicon row has no icon slot")
            #expect(try SidebarLeadingEdgeTests.inkMinX(slot) != nil, "\(c.testDescription): nothing is drawn in the icon slot")
        }
    }

    /// A workspace that is not a site (a terminal) stays text only: the placeholder is for pages.
    @Test func aTerminalWorkspaceStaysTextOnly() throws {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, focusedAt: 1, tabs: [TabSnapshot(surface: 1, kind: .pty, title: "zsh")])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 3, key: nil, name: "workspace-3",
                                                                        screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])])]))
        let workspace = try #require(store.workspaces.first)
        let row = SidebarMapping.shared.row(workspace, machine: .local, pageFace: { _, _, _ in .init() })
        #expect(row.icon == nil, "a terminal workspace drew \(String(describing: row.icon))")
    }
}
