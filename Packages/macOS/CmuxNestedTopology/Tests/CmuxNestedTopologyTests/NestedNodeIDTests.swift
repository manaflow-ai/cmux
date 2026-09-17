import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite struct NestedNodeIDTests {
    @Test func collisionAcrossProviderInstances() {
        let a = NestedTopologyFixtures.nodeID(kind: .pane, rawID: "w1:p1", instance: .init(rawValue: "a"))
        let b = NestedTopologyFixtures.nodeID(kind: .pane, rawID: "w1:p1", instance: .init(rawValue: "b"))
        #expect(a != b)
        #expect(a.rawID == b.rawID)
        #expect(Set([a, b]).count == 2)
    }

    @Test func sameRawIDAcrossKindsAreDistinct() {
        let workspace = NestedTopologyFixtures.nodeID(kind: .workspace, rawID: "shared")
        let pane = NestedTopologyFixtures.nodeID(kind: .pane, rawID: "shared")
        #expect(workspace != pane)
        #expect(workspace.rawID == pane.rawID)
    }

    @Test func codableRoundTripIsStructuredAndVersioned() throws {
        let id = NestedTopologyFixtures.nodeID(kind: .pane, rawID: "w2:p34")
        let data = try JSONEncoder().encode(id)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect(object["provider_kind"] as? String == "herdr")
        #expect(object["provider_instance_id"] as? String == NestedTopologyFixtures.instanceA.rawValue)
        #expect(object["node_kind"] as? String == "pane")
        #expect(object["raw_id"] as? String == "w2:p34")
        let decoded = try JSONDecoder().decode(NestedNodeID.self, from: data)
        #expect(decoded == id)
    }
}
