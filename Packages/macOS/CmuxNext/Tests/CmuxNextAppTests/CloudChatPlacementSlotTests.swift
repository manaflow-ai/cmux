import CmuxNextBridge
import CmuxNextSidebar
import Testing
@testable import CmuxNextApp

/// A started Cloud chat's workspace takes the row its send began in when the sidebar lists the two
/// together, else the top of its machine's rows, never the end (cmux#47677). A Cloud machine's
/// workspaces list in that machine's own section, which never holds this Mac's row: `.above(origin)`
/// alone resolved to nothing there, so the placement was dropped and the chat landed at the bottom.
struct CloudChatPlacementSlotTests {
    private let mac = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    private let cloud = SidebarMachine(id: MachineID("vm-1"), name: "build-vm", kind: .cloud)

    private func section(_ machine: SidebarMachine, _ keys: [String]) -> SidebarRowSection {
        SidebarRowSection(kind: .machine(machine), nodes: keys.map { .workspace(SidebarWorkspace(id: SidebarWorkspaceID($0), title: $0)) })
    }

    @Test func aCloudSectionWithoutTheOriginPutsTheChatFirstNotLast() throws {
        let sections = [section(mac, ["mac-1", "origin", "mac-2"]), section(cloud, ["vm-a", "vm-b", "chat"])]
        #expect(WorkspaceSlot.above("origin").position(moving: ["chat"], section: .machine(cloud.id), in: sections) == nil)
        let resolved = try #require(CloudStartChat.placementSlot(besides: "origin").position(moving: ["chat"], section: .machine(cloud.id), in: sections))
        #expect(resolved.section == .machine(cloud.id))
        #expect(resolved.index == 0)
    }

    @Test func aSectionListingTheOriginKeepsTheChatRightAboveIt() throws {
        let sections = [section(cloud, ["vm-a", "origin", "vm-b", "chat"])]
        let resolved = try #require(CloudStartChat.placementSlot(besides: "origin").position(moving: ["chat"], section: .machine(cloud.id), in: sections))
        #expect(resolved.index == 1)
    }
}
