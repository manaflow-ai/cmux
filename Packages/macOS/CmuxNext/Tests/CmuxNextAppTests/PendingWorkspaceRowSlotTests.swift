@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextSidebar
import Testing

/// Leo 2026-10-29: "when new workspaces are being fucking created, you fucking just make it on the
/// bottom, or you put it right next to it. What the fuck is this conflicting situation?" A new
/// workspace's pending row stands at its slot, and the window's own row for it takes over only where
/// that row stands (`PendingWorkspaceRows.listing`), so the row opens once, at the place it stays.
@MainActor
struct PendingWorkspaceRowSlotTests {
    private let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)

    private func workspace(_ id: String) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(id), title: id)
    }

    private func sections(_ ids: [String]) -> [SidebarRowSection] {
        [SidebarSection(kind: .machine(machine), nodes: ids.map { .workspace(workspace($0)) })]
    }

    private func row(_ id: String, slot: WorkspaceSlot?, byDefault: NewWorkspaceDefaultSlot? = nil) -> PendingWorkspaceRows.Row {
        .init(id: id, window: "w1", machine: CmuxNextSidebar.MachineID.local, face: workspace(id), slot: slot, byDefault: byDefault)
    }

    @Test func aRowListedLastIsNotAtItsSlotRightBelowTheCurrentOne() {
        let new = row("new", slot: .below("a"))
        #expect(!PendingWorkspaceRows.isAtSlot(new, in: sections(["a", "b", "c", "new"]), home: nil))
        #expect(PendingWorkspaceRows.isAtSlot(new, in: sections(["a", "new", "b", "c"]), home: nil))
    }

    @Test func noSlotIsTheEndOfTheLooseRows() {
        let new = row("new", slot: nil)
        #expect(PendingWorkspaceRows.isAtSlot(new, in: sections(["a", "b", "new"]), home: nil))
        #expect(!PendingWorkspaceRows.isAtSlot(new, in: sections(["new", "a", "b"]), home: nil))
    }

    @Test func topByDefaultIsRightBelowHome() {
        let new = row("new", slot: nil, byDefault: NewWorkspaceDefaultSlot(placement: .top, current: "b"))
        #expect(PendingWorkspaceRows.isAtSlot(new, in: sections(["home", "new", "a", "b"]), home: "home"))
        #expect(!PendingWorkspaceRows.isAtSlot(new, in: sections(["home", "a", "b", "new"]), home: "home"))
    }

    @Test func aWorkspaceNotListedOrASlotThatNoLongerResolvesHoldsNothingBack() {
        #expect(PendingWorkspaceRows.isAtSlot(row("new", slot: .below("a")), in: sections(["a", "b"]), home: nil))
        #expect(PendingWorkspaceRows.isAtSlot(row("new", slot: .below("gone")), in: sections(["a", "b", "new"]), home: nil))
    }
}
