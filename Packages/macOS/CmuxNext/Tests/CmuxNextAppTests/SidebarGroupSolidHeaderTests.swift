import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-18 (screen recording of the NIGHTLY sidebar): "There are weird horizontal
/// bars everywhere here, and we also lost the group UI where it's a solid background color."
/// With Minimal Mode on, every group header had become its name beside a hairline (#19936), and
/// every busy workspace drew a full-width indeterminate line under its title. A group header is
/// one solid bar in its color with Minimal Mode on or off, and a busy row with no measured
/// progress draws no line.
@MainActor @Suite(.serialized) struct SidebarGroupSolidHeaderTests {
    private static let group = GroupID("grp-solid")
    private static let busy = WorkspaceID("ws-busy")
    private static let measured = WorkspaceID("ws-measured")

    private static func sidebar(minimal: Bool) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let busy = SidebarWorkspace(id: busy, title: "sidebar", activity: .working(progress: nil),
                                    progress: SidebarProgress(value: nil))
        let measured = SidebarWorkspace(id: measured, title: "build", activity: .busy(progress: 0.5),
                                        progress: SidebarProgress(value: 0.5))
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .group(SidebarGroup(id: group, name: "cmux-next app", color: .blue, workspaces: [busy, measured])),
            ]),
        ])
        let design = DesignSettings()
        design.sidebarSections.minimal = minimal
        let sidebar = SidebarView(model: model, design: design)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        // The settings reach the list on an observation a turn later; draw them in this turn.
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func header(_ sidebar: SidebarView) throws -> GroupHeaderRowView {
        let header = try #require(sidebar.list.rowViews[.group(group)] as? GroupHeaderRowView)
        header.layoutSubtreeIfNeeded()
        header.updateLayer()
        return header
    }

    @Test(arguments: [false, true])
    func aGroupHeaderIsOneSolidBarInItsColor(minimal: Bool) throws {
        let sidebar = Self.sidebar(minimal: minimal)
        // Minimal Mode is on when asked: the header row is shorter than the standard one.
        let row = try #require(sidebar.list.displayed.row(for: .group(Self.group)))
        #expect((row.height < SidebarLayoutMetrics.standard.groupHeaderHeight) == minimal, "minimal \(minimal), header \(row.height) pt")
        let header = try Self.header(sidebar)
        // The bar is the header's full-width rounded layer (as `SidebarGroupChromeLookTests` reads it).
        let bar = try #require(header.layer?.sublayers?.first { !$0.isHidden && $0.frame.width >= header.bounds.width - 0.5 && $0.cornerRadius > 0 },
                               "no full-width rounded bar: the header draws a hairline")
        #expect(bar.frame.height > Metrics.dividerThickness * 4, "a \(bar.frame.height) pt bar is a hairline, not a group bar")
        let fill = try #require(bar.backgroundColor.flatMap { NSColor(cgColor: $0) })
        #expect(fill.alphaComponent > 0.5, "the bar's fill is see-through (\(fill.alphaComponent))")
    }

    @Test(arguments: [false, true])
    func aBusyRowWithoutMeasuredProgressDrawsNoLine(minimal: Bool) throws {
        let sidebar = Self.sidebar(minimal: minimal)
        let busy = try #require(sidebar.list.rowViews[.workspace(Self.busy)] as? WorkspaceRowView)
        #expect(busy.progress == nil)
        #expect(busy.progressTrack.isHidden)
        let measured = try #require(sidebar.list.rowViews[.workspace(Self.measured)] as? WorkspaceRowView)
        #expect(measured.progress?.value == 0.5)
    }

    @Test func aConnectingPlaceholderKeepsItsIndeterminateBar() {
        let ws = SidebarWorkspace(id: WorkspaceID("ws-ssh"), title: "", progress: SidebarProgress(value: nil), rowState: .placeholder)
        #expect(WorkspaceRowContent.bar(ws) != nil)
    }
}
