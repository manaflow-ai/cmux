import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-22: a group header row is exactly as tall as a workspace row at every sidebar
/// density. bfe8483cdb6 only checked the default density; this walks every app density preset,
/// every `sidebar.density` (compact, comfortable, expanded) and Minimal Mode on and off, with the
/// group collapsed and open, loading (its spinner), pinned, and nested one level in. Each case
/// prints a `HEIGHTS|` line so a fleet log shows the measured numbers.
@MainActor @Suite(.serialized) struct SidebarGroupHeaderEveryDensityTests {
    private static let group = GroupID("grp-every")
    private static let pinned = GroupID("grp-pinned")
    private static let parent = GroupID("grp-parent")
    private static let child = GroupID("grp-child")
    private static let member = WorkspaceID("ws-member")
    private static let loose = WorkspaceID("ws-loose")
    private static let rich = WorkspaceID("ws-rich")

    enum Case: String, CaseIterable, Sendable {
        case open, collapsed, loading
    }

    private static func sidebar(density: SidebarDensity, minimal: Bool, shape: Case) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let busy: StatusIndicatorState = shape == .loading ? .busy(progress: nil) : .idle
        var nested = SidebarGroup(id: child, name: "Perf", color: .yellow, isCollapsed: shape != .open,
                                  workspaces: [SidebarWorkspace(id: WorkspaceID("ws-child"), title: "child", activity: busy)])
        nested.parent = parent
        nested.depth = 1
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .group(SidebarGroup(id: pinned, name: "Pinned group", color: .green, isCollapsed: shape != .open, isPinned: true,
                                    workspaces: [SidebarWorkspace(id: WorkspaceID("ws-pinned"), title: "pinned member", activity: busy)])),
                .group(SidebarGroup(id: group, name: "cmux-next app", color: .blue, isCollapsed: shape != .open,
                                    workspaces: [SidebarWorkspace(id: member, title: "member", activity: busy)])),
                .group(SidebarGroup(id: parent, name: "Panes & layout", color: .purple, isCollapsed: false,
                                    workspaces: [SidebarWorkspace(id: WorkspaceID("ws-parent"), title: "parent member")])),
                .group(nested),
                .workspace(SidebarWorkspace(id: loose, title: "loose")),
                .workspace(SidebarWorkspace(id: rich, title: "rich", directory: "~/fun/cmux", branch: "feat-cmux-next")),
            ]),
        ])
        let design = DesignSettings()
        design.sidebarSections.minimal = minimal
        design.sidebarSections.density = density
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 900)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    /// The header's colored bar: its full-width rounded layer.
    private static func barHeight(_ header: GroupHeaderRowView) -> CGFloat? {
        header.layoutSubtreeIfNeeded()
        header.updateLayer()
        return header.layer?.sublayers?.first { !$0.isHidden && $0.frame.width >= header.bounds.width - 0.5 && $0.cornerRadius > 0 }?.frame.height
    }

    /// Runs `body` with `sidebar.density` set on the shared settings the density tokens read.
    private static func withSidebarDensity<T>(_ density: SidebarDensity, _ body: () throws -> T) rethrows -> T {
        let saved = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = saved }
        return try body()
    }

    @Test(arguments: DensityPreset.allCases, SidebarDensity.allCases)
    func everyGroupHeaderIsAsTallAsAWorkspaceRow(preset: DensityPreset, density: SidebarDensity) throws {
        try DensityTokens.$scoped.withValue(preset.tokens) {
            try Self.withSidebarDensity(density) {
                for minimal in [false, true] {
                    for shape in Case.allCases {
                        try Self.check(preset: preset, density: density, minimal: minimal, shape: shape)
                    }
                }
            }
        }
    }

    private static func check(preset: DensityPreset, density: SidebarDensity, minimal: Bool, shape: Case) throws {
        let sidebar = sidebar(density: density, minimal: minimal, shape: shape)
        let list = sidebar.list
        let label = "\(preset.rawValue)/\(density.rawValue)/\(minimal ? "minimal" : "full")/\(shape.rawValue)"
        let row = try #require(list.displayed.row(for: .workspace(loose)), "\(label): no loose row")
        let rowView = try #require(list.rowViews[.workspace(loose)])
        let rich = list.displayed.row(for: .workspace(Self.rich))?.height ?? -1
        let expectedMetrics = minimal ? SidebarLayoutMetrics.standard.minimal : SidebarLayoutMetrics.standard
        var parts = ["row \(row.height)", "rowView \(rowView.frame.height)", "rich \(rich)", "metrics \(expectedMetrics.rowHeight)"]
        #expect(abs(row.height - expectedMetrics.rowHeight) <= 0.5, "\(label): a one-line row is \(row.height), metrics say \(expectedMetrics.rowHeight)")
        for (name, id) in [("group", group), ("pinned", pinned), ("parent", parent), ("child", child)] {
            let slot = try #require(list.displayed.row(for: .group(id)), "\(label): no \(name) header")
            let view = try #require(list.rowViews[.group(id)] as? GroupHeaderRowView, "\(label): no \(name) header view")
            let bar = barHeight(view) ?? -1
            parts.append("\(name) slot \(slot.height) view \(view.frame.height) bar \(bar)")
            #expect(abs(slot.height - row.height) <= 0.5, "\(label): \(name) header slot \(slot.height) vs row \(row.height)")
            #expect(abs(view.frame.height - rowView.frame.height) <= 0.5, "\(label): \(name) header view \(view.frame.height) vs row view \(rowView.frame.height)")
            #expect(abs(bar - rowView.frame.height) <= 0.5, "\(label): \(name) header bar \(bar) vs row view \(rowView.frame.height)")
            for sub in view.subviews where !sub.isHidden {
                #expect(sub.frame.minY >= -0.5 && sub.frame.maxY <= view.bounds.height + 0.5,
                        "\(label): \(name) header part \(type(of: sub)) spans \(sub.frame.minY)...\(sub.frame.maxY) of \(view.bounds.height)")
            }
        }
        if shape == .open, let memberSlot = list.displayed.row(for: .workspace(member)) {
            parts.append("member \(memberSlot.height)")
            #expect(abs(memberSlot.height - row.height) <= 0.5, "\(label): member \(memberSlot.height) vs loose \(row.height)")
        }
        print("HEIGHTS|\(label)|" + parts.joined(separator: "|"))
    }
}
