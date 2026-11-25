import CoreGraphics
@testable import CmuxNextSidebar
import Testing

/// The group band finds the row under a drag card's centre from the rows at or above it
/// (`SidebarGroupBand.shownRow`), not by a scan from the top: it must find the row the scan did, at every y,
/// hidden rows and the gaps between rows included.
struct SidebarGroupBandRowTests {
    @Test func theBandFindsTheRowTheScanFromTheTopFound() {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let loose = (0..<6).map { SidebarNode.workspace(SidebarWorkspace(id: WorkspaceID("gb-l\($0)"), title: "loose \($0)")) }
        let groups = stride(from: 0, to: 40, by: 10).map { start in
            SidebarNode.group(SidebarGroup(id: GroupID("gb-g\(start)"), name: "Group \(start)", color: .green,
                                           workspaces: (start..<start + 10).map {
                                               SidebarWorkspace(id: WorkspaceID("gb-\($0)"), title: "workspace \($0)")
                                           }))
        }
        let sections = [SidebarSection(kind: .machine(machine), nodes: loose + groups)]
        let layout = SidebarLayout.make(sections: sections, metrics: .standard, options: SidebarLayoutOptions())
        let hidden: Set<SidebarRowKey> = [.workspace(WorkspaceID("gb-l2")), .workspace(WorkspaceID("gb-13")), .group(GroupID("gb-g30"))]
        var y: CGFloat = -10
        while y < layout.totalHeight + 10 {
            let scanned = layout.rows.first { y >= $0.y && y < $0.maxY && !hidden.contains($0.key) }
            #expect(SidebarGroupBand.shownRow(at: y, in: layout, hidden: hidden)?.key == scanned?.key, "y=\(y)")
            y += 0.5
        }
    }
}
