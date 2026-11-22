import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextBridge
@testable import CmuxNextDaemon

/// `workspace-group-pin-v1`: a daemon pin reaches the sidebar group, so the
/// header draws the pin and closing the group's workspaces keeps it.
@MainActor
struct SidebarGroupPinTests {
    private func group(_ json: String) throws -> WorkspaceGroupModel {
        WorkspaceGroupModel(try WireCoding.decoder().decode(WorkspaceGroupSnapshot.self, from: Data(json.utf8)))
    }

    /// The mapped sidebar group's pin.
    private func mappedPin(_ model: WorkspaceGroupModel) throws -> Bool {
        let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)
        let sections = SidebarMapping.shared.sections([DaemonSidebarSection(group: model, workspaces: [])], machine: machine)
        let node = try #require(sections.first?.nodes.first)
        guard case let .group(group) = node else {
            Issue.record("expected a group node, got \(node)")
            return false
        }
        return group.isPinned
    }

    @Test func aPinnedGroupIsAPinnedSidebarGroup() throws {
        let pinned = try group(#"{"id":"grp_1","room_id":"default","name":"Saved","color":null,"collapsed":false,"index":0,"pinned":true}"#)
        #expect(try mappedPin(pinned))
    }

    @Test func aGroupWithoutThePinFieldIsNotPinned() throws {
        let older = try group(#"{"id":"grp_2","room_id":"default","name":"Old","color":null,"collapsed":false,"index":0}"#)
        #expect(try mappedPin(older) == false)
    }
}
