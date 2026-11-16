import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-11-15 (msg 33483): "minimal mode should not change density at all". Minimal Mode
/// (`sidebar.minimal`) only hides chrome until the pointer is over the sidebar or the tab bar; at every
/// density (`sidebar.density`) each row, group header, band row and section header is the same height
/// with it on and off, and a row keeps every line it draws.
@MainActor @Suite(.serialized) struct MinimalModeKeepsDensityTests {
    private static let quiet = WorkspaceID("ws-quiet")
    private static let rich = WorkspaceID("ws-rich")
    private static let group = GroupID("grp-density")

    private struct Density: Equatable, CustomStringConvertible {
        var quiet: CGFloat, rich: CGFloat, header: CGFloat, band: CGFloat
        var regionRow: CGFloat, regionHeader: CGFloat
        var layoutRow: CGFloat, layoutSubtitleRow: CGFloat, layoutSectionHeader: CGFloat
        var look: SectionsLookVariant
        var richLines: [Bool]
        var description: String {
            "rows \(quiet)/\(rich), header \(header), band \(band), region \(regionRow)/\(regionHeader), "
                + "metrics \(layoutRow)/\(layoutSubtitleRow)/\(layoutSectionHeader), look \(look), rich lines \(richLines)"
        }
    }

    private static func measure(density: SidebarDensity, minimal: Bool) throws -> Density {
        let saved = (DesignSettings.shared.sidebarSections.density, DesignSettings.shared.sidebarSections.minimal)
        (DesignSettings.shared.sidebarSections.density, DesignSettings.shared.sidebarSections.minimal) = (density, minimal)
        defer { (DesignSettings.shared.sidebarSections.density, DesignSettings.shared.sidebarSections.minimal) = saved }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .group(SidebarGroup(id: group, name: "Agents & routing", color: .purple,
                                    workspaces: [SidebarWorkspace(id: rich, title: "build", directory: "~/src/cmux",
                                                                  branch: "feat-cmux-next", status: "Building",
                                                                  lastActivity: Date(timeIntervalSinceNow: -120))])),
                .workspace(SidebarWorkspace(id: quiet, title: "notes")),
            ]),
        ])
        let design = DesignSettings()
        (design.sidebarSections.density, design.sidebarSections.minimal) = (density, minimal)
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.updateBands()
        sidebar.list.reload(animated: false)
        let layout = sidebar.list.displayed
        let quietRow = try #require(layout.row(for: .workspace(quiet)))
        let richRow = try #require(layout.row(for: .workspace(rich)))
        let header = try #require(layout.row(for: .group(group)))
        let band = try #require(sidebar.aboveRegion.content?.metrics)
        let metrics = SidebarLayoutMetrics.standard.resolved(for: sidebar.model.listOptions())
        let content = richRow.content
        return Density(quiet: quietRow.height, rich: richRow.height, header: header.height, band: band.rowHeight,
                       regionRow: band.rowHeight, regionHeader: band.headerHeight,
                       layoutRow: metrics.rowHeight, layoutSubtitleRow: metrics.rowHeightWithSubtitle,
                       layoutSectionHeader: metrics.sectionHeaderHeight,
                       look: SidebarSectionTunables.currentLook,
                       richLines: [content?.detail != nil, content?.status != nil, content?.badgeTime != nil])
    }

    @Test(arguments: SidebarDensity.allCases)
    func minimalModeLeavesEveryDensityMetricAlone(density: SidebarDensity) throws {
        let off = try Self.measure(density: density, minimal: false)
        let on = try Self.measure(density: density, minimal: true)
        print("MINIMAL-DENSITY|\(density.rawValue)|off: \(off)|on: \(on)")
        #expect(on == off, "\(density.rawValue): minimal mode changed density. off: \(off); on: \(on)")
    }
}
