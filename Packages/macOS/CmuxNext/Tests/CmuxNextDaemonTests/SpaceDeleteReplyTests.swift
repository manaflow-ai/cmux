@testable import CmuxNextDaemon
import Foundation
import Testing

/// SPACE-DELETE-CLOSES-ITS-WORKSPACES: reopening a deleted space with no
/// workspace left to close restores only the space, so the daemon's reply
/// names no workspace.
@Suite struct SpaceDeleteReplyTests {
    @Test func aReopenedSpaceWithNoWorkspaceDecodes() throws {
        let reply = Data(#"{"closed_id":"closed_1","kind":"workspace","workspace_id":null,"workspace_ids":[],"screen_ids":[],"tab_ids":[],"remaining":0}"#.utf8)
        let item = try JSONDecoder().decode(StateResourceClient.ReopenedItem.self, from: reply)
        #expect(item.tabIDs.isEmpty)
    }
}
