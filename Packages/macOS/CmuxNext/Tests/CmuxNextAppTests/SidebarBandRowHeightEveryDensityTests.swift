import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-22: every one-line sidebar row is the same height at every density. Measured on
/// the live NIGHTLY (compact, Minimal Mode on): group headers and workspace rows were both 20 pt, but
/// the band rows above them (Home, App Store, pinned items) stayed 24 pt, because the bands read
/// `SidebarDensityTokens.rowHeight` and ignored Minimal Mode's shorter row.
@MainActor @Suite(.serialized) struct SidebarBandRowHeightEveryDensityTests {
    private static let loose = WorkspaceID("ws-loose")
    private static let group = GroupID("grp-band")

    private static func sidebar(minimal: Bool) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .group(SidebarGroup(id: group, name: "Agents & routing", color: .purple, isCollapsed: true,
                                    workspaces: [SidebarWorkspace(id: WorkspaceID("ws-member"), title: "member")])),
                .workspace(SidebarWorkspace(id: loose, title: "loose")),
            ]),
        ])
        let design = DesignSettings()
        design.sidebarSections.minimal = minimal
        design.sidebarSections.density = DesignSettings.shared.sidebarSections.density
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.updateBands()
        sidebar.list.reload(animated: false)
        return sidebar
    }

    @Test(arguments: SidebarDensity.allCases, [false, true])
    func bandRowsAreAsTallAsWorkspaceRowsAndGroupHeaders(density: SidebarDensity, minimal: Bool) throws {
        let saved = (DesignSettings.shared.sidebarSections.density, DesignSettings.shared.sidebarSections.minimal)
        (DesignSettings.shared.sidebarSections.density, DesignSettings.shared.sidebarSections.minimal) = (density, minimal)
        defer { (DesignSettings.shared.sidebarSections.density, DesignSettings.shared.sidebarSections.minimal) = saved }
        let sidebar = Self.sidebar(minimal: minimal)
        let row = try #require(sidebar.list.displayed.row(for: .workspace(Self.loose))).height
        let header = try #require(sidebar.list.displayed.row(for: .group(Self.group))).height
        let band = try #require(sidebar.aboveRegion.content?.metrics.rowHeight)
        let label = "\(density.rawValue)/\(minimal ? "minimal" : "full"): band row \(band), group header \(header), workspace row \(row)"
        print("BANDHEIGHTS|\(label)")
        #expect(abs(header - row) <= 0.5, "\(label)")
        // A band row (Home, App Store, a pinned link) is one line: as tall as a one-line workspace row. In
        // Expanded, workspace rows and group headers take two lines (SidebarLayoutMetrics.rowStep); band rows
        // stay one line, the same height as compact's.
        let oneLine = minimal ? SidebarLayoutMetrics.standard.minimal.rowHeight : SidebarLayoutMetrics.standard.rowHeight
        let expected = density == .expanded && !minimal ? oneLine : row
        #expect(abs(band - expected) <= 0.5, "a band row (Home, pinned) differs from a one-line workspace row: \(label)")
        // Every list item the band placed (not a header, tile or app) is that one height.
        for placed in sidebar.aboveRegion.layoutResult.rows {
            guard case .item = placed.kind else { continue }
            #expect(abs(placed.frame.height - expected) <= 0.5, "\(label): a band item is \(placed.frame.height)")
        }
    }
}
