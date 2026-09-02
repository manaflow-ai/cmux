import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct NestedTopologyCodableTests {
    @Test func snapshotRoundTrip() throws {
        let snapshot = NestedTopologyFixtures.snapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(NestedTopologySnapshot.self, from: data)
        #expect(decoded == snapshot)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["encoding_version"] as? Int == 1)
        #expect(object["attachment_id"] != nil)
        #expect(object["host_stable_surface_id"] != nil)
    }

    @Test func eventRoundTrips() throws {
        let snapshot = NestedTopologyFixtures.snapshot()
        let tree = NestedTopologyFixtures.baseTree()
        let events: [NestedTopologyEvent] = [
            .replaceSnapshot(snapshot),
            .workspaceUpserted(tree.workspace),
            .workspaceClosed(tree.workspace.id),
            .tabUpserted(tree.tab),
            .tabClosed(tree.tab.id),
            .paneUpserted(tree.pane),
            .paneClosed(tree.pane.id),
            .agentUpserted(tree.agent),
            .agentClosed(tree.agent.id),
            .focusChanged(snapshot.focus),
            .titleUpdated(id: tree.pane.id, displayTitle: "New"),
            .agentStatusUpdated(id: tree.agent.id, status: .working, providerRawStatus: "working"),
        ]
        for event in events {
            let data = try JSONEncoder().encode(event)
            let decoded = try JSONDecoder().decode(NestedTopologyEvent.self, from: data)
            #expect(decoded == event)
        }
    }

    @Test func capabilityAndConnectionStateRoundTrip() throws {
        let capabilities = NestedCapabilitySet(capabilities: [.topologySnapshotV1, .topologyFocusV1])
        let data = try JSONEncoder().encode(capabilities)
        let decoded = try JSONDecoder().decode(NestedCapabilitySet.self, from: data)
        #expect(decoded == capabilities)
        #expect(decoded.sortedRawValues == ["topology.focus.v1", "topology.snapshot.v1"])

        for state in NestedConnectionState.allCases {
            let encoded = try JSONEncoder().encode(state)
            let roundTrip = try JSONDecoder().decode(NestedConnectionState.self, from: encoded)
            #expect(roundTrip == state)
        }
    }

    @Test func associationRecordRoundTripKeepsExplicitFlags() throws {
        let key = NestedAssociationKey(
            nodeID: NestedTopologyFixtures.nodeID(kind: .pane, rawID: "w1:p1"),
            sessionRawID: "sess-1",
            providerInstanceGeneration: NestedTopologyFixtures.instanceA
        )
        let record = NestedAssociationRecord(
            key: key,
            parentID: NestedTopologyFixtures.nodeID(kind: .tab, rawID: "w1:t1"),
            heuristicSatisfied: true,
            titleLock: .locked("Locked", authority: .user)
        )
        let data = try JSONEncoder().encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["heuristic_satisfied"] as? Bool == true)
        let lock = try #require(object["title_lock"] as? [String: Any])
        #expect(lock["is_locked"] as? Bool == true)
        let decoded = try JSONDecoder().decode(NestedAssociationRecord.self, from: data)
        #expect(decoded == record)
    }
}
