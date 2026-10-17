import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-13 ("this left sidebar ui is very bad"): a busy row drew a
/// full-width line along the pill's bottom edge whether or not anything
/// measured progress. A row now draws a bar only for a measured fraction (or
/// an error), inside the pill, spanning the content between the row's insets.
@MainActor @Suite(.serialized) struct SidebarRowQuietProgressTests {
    private static let busyID = WorkspaceID("ws-busy")
    private static let measuredID = WorkspaceID("ws-measured")

    private static func sidebar() -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let busy = SidebarWorkspace(id: busyID, title: "workspace-26", unread: .count(1),
                                    activity: .working(progress: nil), progress: SidebarProgress(value: nil))
        let measured = SidebarWorkspace(id: measuredID, title: "build", activity: .busy(progress: 0.5),
                                        progress: SidebarProgress(value: 0.5))
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [.workspace(busy), .workspace(measured)]),
        ], activeWorkspaceID: busyID)
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func row(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
    }

    @Test func indeterminateProgressDrawsNoBar() throws {
        let row = try Self.row(Self.sidebar(), Self.busyID)
        #expect(row.progress == nil)
        #expect(row.progressTrack.isHidden)
    }

    @Test func measuredProgressSitsInsideThePillBetweenTheRowInsets() throws {
        let row = try Self.row(Self.sidebar(), Self.measuredID)
        let track = row.progressTrack.frame
        #expect(!row.progressTrack.isHidden)
        #expect(track.minX == SidebarStyle.horizontalInset)
        #expect(row.bounds.width - track.maxX == SidebarStyle.horizontalInset)
        #expect(track.maxY <= row.bounds.height - Metrics.space1)
        #expect(abs(row.progressFill.frame.width - track.width / 2) < 0.5)
    }

    @Test func aConnectingPlaceholderKeepsItsIndeterminateBar() {
        let ws = SidebarWorkspace(id: WorkspaceID("ws-ssh"), title: "", progress: SidebarProgress(value: nil), rowState: .placeholder)
        #expect(WorkspaceRowContent.bar(ws) != nil)
    }
}
