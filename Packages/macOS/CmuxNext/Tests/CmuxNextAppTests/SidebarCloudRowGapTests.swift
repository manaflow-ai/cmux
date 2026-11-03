import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CoreGraphics
import Testing

/// In one list, this Mac's rows and a Cloud machine's rows follow each other by the row spacing: no band opens
/// between the last local row and the first Cloud row (Leo 2026-11-01: "this strange dead zone gap that occurs
/// between cloud and non-cloud workspaces"). Drawn through the real list, so the row views' frames are checked, not
/// only the layout's rows.
@MainActor @Suite(.serialized) struct SidebarCloudRowGapTests {
    private static func machine(_ name: String, kind: SidebarMachine.Kind, status: SidebarMachine.Status = .connected,
                                _ ids: [String]) -> SidebarSection {
        let id: MachineID = kind == .local ? .local : MachineID(name)
        return SidebarSection(kind: .machine(SidebarMachine(id: id, name: name, kind: kind, status: status)),
                              nodes: ids.map { .workspace(SidebarWorkspace(id: WorkspaceID($0), machineID: id, title: "workspace-\($0)")) })
    }

    /// The drawn workspace rows, top to bottom, with their frames in the list.
    private static func drawnRows(_ sections: [SidebarSection], selected: String? = nil) -> [(key: SidebarRowKey, frame: NSRect)] {
        let model = SidebarModel(sections: sections, activeWorkspaceID: selected.map { WorkspaceID($0) })
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        let rows = sidebar.list.rowViews.compactMap { key, view -> (key: SidebarRowKey, frame: NSRect)? in
            guard case .workspace = key, !view.isHidden, view.alphaValue > 0 else { return nil }
            return (key, view.frame)
        }
        return rows.sorted { $0.frame.minY < $1.frame.minY }
    }

    /// Every drawn row starts the same distance under the one above it as the two local rows do.
    private static func expectEvenPitch(_ sections: [SidebarSection], selected: String? = nil, _ label: String,
                                        sourceLocation: SourceLocation = #_sourceLocation) {
        let rows = drawnRows(sections, selected: selected)
        let keys = rows.map(\.key)
        #expect(Set(keys).count == keys.count, "\(label): a key drew twice: \(keys)", sourceLocation: sourceLocation)
        guard rows.count >= 3 else {
            Issue.record("\(label): drew \(rows.count) rows", sourceLocation: sourceLocation)
            return
        }
        let spacing = rows[1].frame.minY - rows[0].frame.maxY
        for (above, below) in zip(rows, rows.dropFirst()) {
            let gap = below.frame.minY - above.frame.maxY
            #expect(abs(gap - spacing) < 0.5, "\(label): \(below.key) starts \(gap - spacing) pt late under \(above.key)",
                    sourceLocation: sourceLocation)
        }
    }

    @Test func aCloudRowFollowsTheLastLocalRowByTheRowSpacing() {
        let sections = [Self.machine("This Mac", kind: .local, ["1l", "2"]), Self.machine("sr2-tunnel-probe", kind: .cloud, ["1"])]
        Self.expectEvenPitch(sections, selected: "2", "one Cloud machine")
    }

    /// Cloud machines made from one image list its workspace ids again (Leo's capture: two "workspace-1" tabs).
    @Test func cloudMachinesSharingAWorkspaceIDLeaveNoBand() {
        let sections = [Self.machine("This Mac", kind: .local, ["1l", "2"]),
                        Self.machine("sr2-tunnel-a", kind: .cloud, ["1"]),
                        Self.machine("sr2-tunnel-b", kind: .cloud, ["1"]),
                        Self.machine("sr2-tunnel-c", kind: .cloud, ["3"])]
        Self.expectEvenPitch(sections, selected: "2", "cloned Cloud machines")
    }

    /// A Cloud machine that lists a workspace id this Mac lists too draws only this Mac's row.
    @Test func aCloudCopyOfALocalWorkspaceLeavesNoBand() {
        let sections = [Self.machine("This Mac", kind: .local, ["1l", "2"]),
                        Self.machine("sr2-tunnel-a", kind: .cloud, ["2", "1"])]
        Self.expectEvenPitch(sections, selected: "2", "a Cloud copy of a local id")
    }

    /// A Cloud machine with no workspace, between this Mac and one that has some, takes no room.
    @Test func anEmptyCloudMachineBetweenLeavesNoBand() {
        for status: SidebarMachine.Status in [.connected, .connecting, .paused, .disconnected, .failed] {
            let sections = [Self.machine("This Mac", kind: .local, ["1l", "2"]),
                            Self.machine("sr2-tunnel-empty", kind: .cloud, status: status, []),
                            Self.machine("sr2-tunnel-probe", kind: .cloud, ["1"])]
            Self.expectEvenPitch(sections, selected: "2", "an empty \(status) Cloud machine")
        }
    }

    /// A Cloud machine that is not connected yet draws its rows at the same pitch.
    @Test func aCloudMachineInAnyStateLeavesNoBand() {
        for status: SidebarMachine.Status in [.connecting, .reconnecting, .paused, .disconnected, .failed, .unreachable] {
            let sections = [Self.machine("This Mac", kind: .local, ["1l", "2"]),
                            Self.machine("sr2-tunnel-probe", kind: .cloud, status: status, ["1"])]
            Self.expectEvenPitch(sections, selected: "2", "a \(status) Cloud machine")
        }
    }
}
