import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite("Nested topology Codable contract")
struct NestedTopologyCodableTests {
    @Test("a complete snapshot round-trips without losing authority or raw provider state")
    func snapshotRoundTrip() throws {
        let fixture = NestedTopologyTestFixture()
        let snapshot = try fixture.snapshot(
            capabilities: NestedProviderCapabilities([
                .topologyEvents,
                .topologySnapshot,
                NestedProviderCapability(rawValue: "vendor.future.v2"),
            ]),
            panes: [fixture.pane(
                title: NestedNodeTitle(value: "Locked", authority: .user),
                associationAuthority: .heuristic,
                heuristicAlreadySatisfied: true
            )],
            agents: [fixture.agent(status: NestedAgentStatus(
                presentation: .unknown,
                providerRawValue: "future-state"
            ))],
            focus: NestedTopologyFocus(
                workspaceID: fixture.id("workspace-1", kind: .workspace),
                tabID: fixture.id("tab-1", kind: .tab),
                paneID: fixture.id("pane-1", kind: .pane),
                agentID: fixture.id("agent-1", kind: .agent)
            )
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(NestedTopologySnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.capabilities.values.map(\.rawValue) == [
            "topology.events.v1",
            "topology.snapshot.v1",
            "vendor.future.v2",
        ])
    }

    @Test("events round-trip as typed structured mutations")
    func eventRoundTrip() throws {
        let fixture = NestedTopologyTestFixture()
        let event = fixture.event(.paneUpdated(node: fixture.pane(
            title: NestedNodeTitle(value: "Renamed", authority: .provider)
        )))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(NestedTopologyEvent.self, from: data)

        #expect(decoded == event)
    }

    @Test("unsupported public node-ID versions fail closed")
    func rejectsUnsupportedIdentityVersion() throws {
        let id = NestedTopologyTestFixture().id("pane-1", kind: .pane)
        let data = try JSONEncoder().encode(id)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 255
        let unsupported = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NestedNodeID.self, from: unsupported)
        }
    }

    @Test("provider capabilities are deduplicated and encoded deterministically")
    func capabilitySetOrdering() throws {
        let capabilities = NestedProviderCapabilities([
            .topologySnapshot,
            .topologyEvents,
            .topologySnapshot,
        ])
        let data = try JSONEncoder().encode(capabilities)
        let decoded = try JSONDecoder().decode(NestedProviderCapabilities.self, from: data)

        #expect(capabilities.values.map(\.rawValue) == [
            "topology.events.v1",
            "topology.snapshot.v1",
        ])
        #expect(decoded == capabilities)
        #expect(decoded.contains(.topologySnapshot))
        #expect(!decoded.contains(.topologyFocus))
    }

    @Test("connection state values have stable raw encodings")
    func connectionStateRoundTrip() throws {
        for state in NestedProviderConnectionState.allCases {
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(NestedProviderConnectionState.self, from: data)
            #expect(decoded == state)
        }
    }

    @Test("custom validation limits can be supplied when decoding a snapshot")
    func customLimitRoundTrip() throws {
        let fixture = NestedTopologyTestFixture()
        let standard = NestedTopologyLimits.standard
        let limits = NestedTopologyLimits(
            maximumWorkspaces: standard.maximumWorkspaces,
            maximumTabs: standard.maximumTabs,
            maximumPanes: standard.maximumPanes,
            maximumAgents: standard.maximumAgents,
            maximumTotalNodes: standard.maximumTotalNodes,
            maximumEventsPerBatch: standard.maximumEventsPerBatch,
            maximumDepth: standard.maximumDepth,
            maximumIdentifierBytes: standard.maximumIdentifierBytes + 1,
            maximumTitleBytes: standard.maximumTitleBytes,
            maximumRawStatusBytes: standard.maximumRawStatusBytes,
            maximumSessionIDBytes: standard.maximumSessionIDBytes,
            maximumCapabilities: standard.maximumCapabilities,
            maximumCapabilityBytes: standard.maximumCapabilityBytes
        )
        let rawID = String(repeating: "i", count: limits.maximumIdentifierBytes)
        let snapshot = try fixture.snapshot(
            capabilities: NestedProviderCapabilities([]),
            workspaces: [fixture.workspace(rawID, title: nil)],
            tabs: [],
            panes: [],
            agents: [],
            limits: limits
        )
        let data = try JSONEncoder().encode(snapshot)

        #expect(throws: NestedTopologyError.self) {
            try JSONDecoder().decode(NestedTopologySnapshot.self, from: data)
        }

        let decoder = JSONDecoder()
        decoder.userInfo[NestedTopologySnapshot.decodingLimitsUserInfoKey] = limits
        let decoded = try decoder.decode(NestedTopologySnapshot.self, from: data)
        #expect(decoded == snapshot)
    }
}
