@testable import CmuxNextDaemon
import Foundation
import Testing

@Suite struct GeneratedTreeDecodeTests {
    private func workspace(_ fields: String) throws -> WorkspaceSnapshot {
        try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data("{\"id\":1\(fields)}".utf8))
    }

    @Test func keepAwakeSurvivesTheGeneratedSnapshot() throws {
        #expect(try workspace(",\"keep_awake\":true").keepAwake)
        #expect(try !workspace(",\"keep_awake\":false").keepAwake)
        #expect(try !workspace("").keepAwake)
    }

    @Test func nameRevisionAcceptsCurrentAndLegacyWireValues() throws {
        #expect(try workspace(",\"name_revision\":\"18446744073709551615\"").nameRevision == UInt64.max)
        #expect(try workspace(",\"name_revision\":42").nameRevision == 42)
        for value in ["null", "\"invalid\"", "\"18446744073709551616\"", "-1", "{}"] {
            #expect(try workspace(",\"name_revision\":\(value)").nameRevision == 0)
        }
        #expect(try workspace("").nameRevision == 0)
    }

    @Test func missingPaneStateStillDecodesAsAnEmptyPane() throws {
        let pane = try JSONDecoder().decode(PaneSnapshot.self, from: Data(#"{"id":1,"dead":true}"#.utf8))
        #expect(pane.tabs.isEmpty)
        #expect(pane.tabGroups.isEmpty)
        #expect(pane.activeTab == 0)
        #expect(pane.focusedAt == 0)
        #expect(pane.dead)
        let live = try JSONDecoder().decode(PaneSnapshot.self, from: Data(#"{"id":1}"#.utf8))
        #expect(!live.dead)
        #expect(PaneSnapshot(id: 1, dead: true).dead)
    }

    @Test func legacyInlineSavedGroupsStillDecode() throws {
        let tree = try JSONDecoder().decode(DaemonTree.self, from: Data(
            #"{"saved_tab_groups":[{"id":"saved_1","name":"Saved"}]}"#.utf8))
        #expect(tree.savedTabGroups.count == 1)
        #expect(tree.savedTabGroups.first?.name == "Saved")
        #expect(try JSONDecoder().decode(DaemonTree.self, from: Data(#"{}"#.utf8)).savedTabGroups.isEmpty)
    }

    @Test func sharedAndPersonalGroupsUseTheSameSnapshot() throws {
        let decoder = JSONDecoder()
        let shared = try decoder.decode(WorkspaceGroupSnapshot.self, from: Data(#"{"id":"group_1"}"#.utf8))
        #expect(shared.profile == nil)
        #expect(shared.topIndex == nil)
        #expect(!shared.pinned)
        let personal = try decoder.decode(WorkspaceGroupSnapshot.self, from: Data(
            #"{"id":"group_1","profile":"profile_1","top_index":3,"icon":"star","pinned":true}"#.utf8))
        #expect(personal.profile?.rawValue == "profile_1")
        #expect(personal.topIndex == 3)
        #expect(personal.icon == "star")
        #expect(personal.pinned)
        #expect(personal.parent == nil)
        #expect(personal.depth == 0)
    }
}
