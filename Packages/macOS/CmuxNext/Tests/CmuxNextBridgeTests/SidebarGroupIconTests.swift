import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextBridge
@testable import CmuxNextDaemon

/// `workspace-group-icon-v1`: a daemon group icon reaches the sidebar group,
/// so the header draws it in the group's label.
@MainActor
struct SidebarGroupIconTests {
    private func mapped(_ json: String) throws -> SidebarGroup? {
        let model = WorkspaceGroupModel(try WireCoding.decoder().decode(WorkspaceGroupSnapshot.self, from: Data(json.utf8)))
        let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)
        let sections = SidebarMapping.shared.sections([DaemonSidebarSection(group: model, workspaces: [])], machine: machine)
        guard case let .group(group)? = sections.first?.nodes.first else { return nil }
        return group
    }

    @Test func aSymbolIconReachesTheSidebarGroup() throws {
        let group = try mapped(#"{"id":"grp_1","room_id":"default","name":"Work","color":"blue","collapsed":false,"index":0,"icon":"star.fill"}"#)
        #expect(group?.icon == .symbol("star.fill"))
    }

    @Test func anEmojiIconReachesTheSidebarGroup() throws {
        let group = try mapped(#"{"id":"grp_2","room_id":"default","name":"Fun","color":null,"collapsed":false,"index":0,"icon":"🚀"}"#)
        #expect(group?.icon == .emoji("🚀"))
    }

    @Test func aGroupWithoutAnIconHasNone() throws {
        let group = try mapped(#"{"id":"grp_3","room_id":"default","name":"Old","color":null,"collapsed":false,"index":0}"#)
        #expect(group != nil)
        #expect(group?.icon == nil)
    }
}
