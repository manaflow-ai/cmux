import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSidebar
import Testing

/// Exercises the settings parser and live applier against existing AppKit rows, including a
/// weight-only change (which must invalidate the rows even when their geometry stays equal).
@MainActor @Suite(.serialized)
struct SidebarAppearanceLiveSettingsTests {
    @Test(arguments: DensityPreset.allCases)
    func textAndRowsCanBeSizedIndependently(preset: DensityPreset) throws {
        let design = DesignSettings.shared
        let saved = design.sidebarSections
        let savedDensity = design.densityTokens
        defer { design.sidebarSections = saved; design.densityTokens = savedDensity }
        try DensityTokens.$scoped.withValue(preset.tokens) {
            let applier = SettingsApplier(design: design, registry: ActionRegistry())
            let model = SidebarModel(sections: [SidebarSection(
                kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)),
                nodes: [
                    .group(SidebarGroup(id: GroupID("appearance-group"), name: "Chief", color: .blue,
                                        workspaces: [SidebarWorkspace(id: WorkspaceID("appearance-member"), title: "Member")])),
                    .workspace(SidebarWorkspace(id: WorkspaceID("appearance-loose"), title: "Workspace")),
                ]
            )])
            let sidebar = SidebarView(model: model, design: design)
            sidebar.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
            func apply(_ values: [String: JSONValue]) {
                let root: JSONValue = .object(["sidebar": .object(values)])
                let snapshot = CmuxConfigSnapshot.parse(root, validDensities: SettingsApplier.validDensities,
                                                        validMetrics: SettingsApplier.validMetrics)
                applier.apply(snapshot)
                sidebar.renderNow()
                sidebar.layoutSubtreeIfNeeded()
                sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
            }
            apply([:])
            let original = SidebarStyle.titleFont
            apply(["fontSize": 18, "fontWeight": "medium", "rowHeight": 28, "rowSpacing": 1])
            let row = try #require(sidebar.list.rowViews[.workspace(WorkspaceID("appearance-loose"))] as? WorkspaceRowView)
            let header = try #require(sidebar.list.rowViews[.group(GroupID("appearance-group"))] as? GroupHeaderRowView)
            #expect(row.title.font == Typography.system(size: 18, weight: .medium))
            #expect(header.name.font == Typography.system(size: 18, weight: .medium))
            #expect(row.frame.height == 28)
            #expect(header.frame.height == row.frame.height)
            let member = try #require(sidebar.list.displayed.row(for: .workspace(WorkspaceID("appearance-member"))))
            let loose = try #require(sidebar.list.displayed.row(for: .workspace(WorkspaceID("appearance-loose"))))
            #expect(abs(loose.y - member.maxY - 1) < 0.01)

            // Geometry is unchanged: the existing row must still get the new font.
            apply(["fontSize": 18, "fontWeight": "semibold", "rowHeight": 28, "rowSpacing": 1])
            #expect(row.title.font == Typography.system(size: 18, weight: .semibold))
            #expect(header.name.font == Typography.system(size: 18, weight: .semibold))

            apply(["fontSize": 18, "fontWeight": "regular", "rowHeight": 28, "minimal": true])
            #expect(row.frame.height == 28)
            #expect(row.title.font == Typography.system(size: 18, weight: .regular))

            // Removing the keys restores the preset, without restarting the app.
            apply([:])
            #expect(row.title.font == original)
            #expect(row.frame.height == SidebarLayoutMetrics.standard.rowHeight)
        }
    }

    @Test func theLargestTextFitsShortRowsAndGroupHeaders() throws {
        let design = DesignSettings.shared
        let saved = design.sidebarSections
        defer { design.sidebarSections = saved }
        let snapshot = CmuxConfigSnapshot.parse(.object(["sidebar": .object([
            "fontSize": 32, "fontWeight": "semibold", "rowHeight": 20, "minimal": true,
        ])]), validDensities: [], validMetrics: [])
        SettingsApplier(design: design, registry: ActionRegistry()).apply(snapshot)
        let font = SidebarStyle.titleFont
        #expect(font.pointSize == 32)
        let line = ceil(NSLayoutManager().defaultLineHeight(for: font))
        let metrics = SidebarLayoutMetrics.standard.minimal
        #expect(metrics.rowHeight >= line)
        let content = SidebarStyle.groupHeaderContentHeight(rowHeight: metrics.rowHeight)
        #expect(content >= line)
        #expect(SidebarStyle.groupHeaderFont(barHeight: content).pointSize == 32)
    }
}
