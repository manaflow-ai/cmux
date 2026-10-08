@testable import CmuxNextDaemon
import Foundation
import Testing

/// SPACE-DELETE-CLOSES-ITS-WORKSPACES: a reopen that brings back only a
/// deleted space may name no workspace; the reply still decodes.
@Suite struct SpaceDeleteReplyTests {
    @Test func aReopenedSpaceWithNoWorkspaceDecodes() throws {
        let reply = Data(#"{"closed_id":"closed_1","kind":"workspace","workspace_id":null,"workspace_ids":[],"screen_ids":[],"tab_ids":[],"remaining":0}"#.utf8)
        let item = try JSONDecoder().decode(StateResourceClient.ReopenedItem.self, from: reply)
        #expect(item.tabIDs.isEmpty)
    }

    @Test func deleteSpaceReturnsItsClosedGroup() throws {
        let reply = Data(#"{"profile":"prof_a","moved_to":null,"unpinned":[],"closed_id":"closed_2"}"#.utf8)
        let response = try JSONDecoder().decode(DeleteProfileRequest.Response.self, from: reply)
        #expect(response.closedID == "closed_2")
    }
}
