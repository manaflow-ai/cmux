import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// No sidebar row runs past the sidebar's edge at any density (plans/cmux-next/density-DESIGN.md;
/// Lawrence 2026-10-20 saw Comfortable rows overflow, a288). Every row is laid out at each
/// built-in density through `DensityTokens.$scoped`, at a narrow and a wide sidebar.
@MainActor @Suite(.serialized) struct DensitySidebarOverflowTests {
    private static let group = GroupID("grp-density")

    private static func sidebar(width: CGFloat) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .group(SidebarGroup(id: group, name: "cmux-next app", color: .blue, isCollapsed: false,
                                    workspaces: [SidebarWorkspace(id: WorkspaceID("ws-in-group"), title: "redesigning source control")])),
                .workspace(SidebarWorkspace(id: WorkspaceID("ws-loose"), title: "a workspace with a rather long title that truncates")),
            ]),
        ])
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    @Test(arguments: DensityPreset.allCases, [CGFloat(180), 300])
    func everyRowStaysInsideTheSidebar(preset: DensityPreset, width: CGFloat) throws {
        try DensityTokens.$scoped.withValue(preset.tokens) {
            let sidebar = Self.sidebar(width: width)
            #expect(!sidebar.list.rowViews.isEmpty)
            for (key, row) in sidebar.list.rowViews {
                let frame = row.convert(row.bounds, to: sidebar)
                #expect(frame.minX >= -0.5 && frame.maxX <= width + 0.5, "\(preset) at \(width) pt: \(key) spans \(frame.minX)...\(frame.maxX)")
                for layer in row.layer?.sublayers ?? [] where !layer.isHidden {
                    #expect(layer.frame.maxX <= row.bounds.width + 0.5, "\(preset) at \(width) pt: a layer of \(key) runs past its row")
                }
            }
            let header = try #require(sidebar.list.displayed.row(for: .group(Self.group)))
            #expect(header.height == SidebarLayoutMetrics.standard.rowHeight, "\(preset): the header is a row tall")
        }
    }
}
