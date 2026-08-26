import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite("Nested topology Codable contract")
struct NestedTopologyCodableTests {
    @Test("a complete snapshot round-trips without losing authority or raw provider state")
    func snapshotRoundTrip() throws {
        let fixture = NestedTopologyTestFixture()
        let providerSnapshot = try fixture.snapshot(
            capabilities: NestedProviderCapabilities([
                .topologyEvents,
                .topologySnapshot,
                NestedProviderCapability(rawValue: "vendor.future.v2"),
            ]),
            panes: [fixture.pane(
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
        let snapshot = try NestedTopologyReducer().applying(
            .user(nodeID: fixture.id("pane-1", kind: .pane), value: "Locked"),
            to: providerSnapshot
        )
        let data = try JSONEncoder().encode(snapshot)

        #expect(throws: NestedTopologyError.invalidProviderTitleAuthority(
            node: fixture.id("pane-1", kind: .pane),
            authority: .user
        )) {
            try JSONDecoder().decode(NestedTopologySnapshot.self, from: data)
        }

        let decoder = JSONDecoder()
        decoder.userInfo[NestedTopologySnapshot.decodingModeUserInfoKey] =
            NestedTopologySnapshotDecodingMode.trustedPublishedSnapshot
        let decoded = try decoder.decode(NestedTopologySnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.capabilities.values.map(\.rawValue) == [
            "topology.events.v1",
            "topology.snapshot.v1",
            "vendor.future.v2",
        ])
    }

    @Test("opaque protocol bytes survive JSON and property-list round trips")
    func opaqueProtocolUTF8RoundTrip() throws {
        let leadingByteOrderMark = "\u{FEFF}"
        let provider = NestedProviderIdentity(
            kind: NestedProviderKind(rawValue: "\(leadingByteOrderMark)herdr"),
            instanceID: NestedProviderInstanceID(
                rawValue: "\(leadingByteOrderMark)provider",
                generation: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
            )
        )
        func id(_ rawID: String, kind: NestedNodeKind) -> NestedNodeID {
            NestedNodeID(
                provider: provider,
                kind: kind,
                rawID: "\(leadingByteOrderMark)\(rawID)"
            )
        }
        let workspaceID = id("workspace", kind: .workspace)
        let tabID = id("tab", kind: .tab)
        let paneID = id("pane", kind: .pane)
        let agentID = id("agent", kind: .agent)
        let snapshot = try NestedTopologySnapshot(
            provider: provider,
            capabilities: NestedProviderCapabilities([
                NestedProviderCapability(rawValue: "\(leadingByteOrderMark)capability"),
            ]),
            workspaces: [NestedWorkspaceNode(
                id: workspaceID,
                order: 0,
                title: nil
            )],
            tabs: [NestedTabNode(
                id: tabID,
                workspaceID: workspaceID,
                order: 0,
                title: nil
            )],
            panes: [NestedPaneNode(
                id: paneID,
                association: NestedParentAssociation(
                    key: NestedAssociationKey(
                        paneID: paneID,
                        sessionID: "\(leadingByteOrderMark)pane-session"
                    ),
                    tabID: tabID,
                    authority: .provider,
                    heuristicAlreadySatisfied: false
                ),
                order: 0,
                title: nil
            )],
            agents: [NestedAgentNode(
                id: agentID,
                paneID: paneID,
                sessionID: "\(leadingByteOrderMark)agent-session",
                order: 0,
                title: nil,
                status: NestedAgentStatus(
                    presentation: .idle,
                    providerRawValue: "\(leadingByteOrderMark)idle"
                )
            )],
            focus: .none
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(NestedTopologySnapshot.self, from: data)

        #expect(decoded.provider == snapshot.provider)
        #expect(decoded.capabilities == snapshot.capabilities)
        #expect(decoded.workspaces[0].id == workspaceID)
        #expect(decoded.panes[0].association.key == snapshot.panes[0].association.key)
        #expect(decoded.agents[0].sessionID.map(ExactUTF8String.init)
            == snapshot.agents[0].sessionID.map(ExactUTF8String.init))
        #expect(decoded.agents[0].status == snapshot.agents[0].status)
        #expect(decoded == snapshot)

        let propertyListData = try PropertyListEncoder().encode(snapshot)
        let propertyListDecoded = try PropertyListDecoder().decode(
            NestedTopologySnapshot.self,
            from: propertyListData
        )

        #expect(propertyListDecoded.provider == snapshot.provider)
        #expect(propertyListDecoded.capabilities == snapshot.capabilities)
        #expect(propertyListDecoded.workspaces[0].id == workspaceID)
        #expect(propertyListDecoded.panes[0].association.key == snapshot.panes[0].association.key)
        #expect(propertyListDecoded.agents[0].sessionID.map(ExactUTF8String.init)
            == snapshot.agents[0].sessionID.map(ExactUTF8String.init))
        #expect(propertyListDecoded.agents[0].status == snapshot.agents[0].status)
        #expect(propertyListDecoded == snapshot)
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
        let standard = NestedTopologyLimits()
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

    @Test("decoding rejects an oversized node collection before decoding its elements")
    func boundedCollectionDecoding() throws {
        let fixture = NestedTopologyTestFixture()
        let snapshot = try fixture.snapshot(
            capabilities: NestedProviderCapabilities([]),
            workspaces: [fixture.workspace()],
            tabs: [],
            panes: [],
            agents: []
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let workspaces = try #require(object["workspaces"] as? [Any])
        object["workspaces"] = [try #require(workspaces.first), NSNull()]
        let oversized = try JSONSerialization.data(withJSONObject: object)
        let limits = fixture.limits(maximumWorkspaces: 1)
        let decoder = JSONDecoder()
        decoder.userInfo[NestedTopologySnapshot.decodingLimitsUserInfoKey] = limits

        #expect(throws: NestedTopologyError.nodeLimitExceeded(
            kind: .workspace,
            actual: 2,
            maximum: 1
        )) {
            try decoder.decode(NestedTopologySnapshot.self, from: oversized)
        }
    }

    @Test("decoding rejects an oversized capability collection before decoding its elements")
    func boundedCapabilityDecoding() throws {
        let fixture = NestedTopologyTestFixture()
        let encoded = try JSONEncoder().encode(fixture.snapshot())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let capabilities = try #require(object["capabilities"] as? [Any])
        object["capabilities"] = [try #require(capabilities.first), NSNull()]
        let oversized = try JSONSerialization.data(withJSONObject: object)
        let limits = fixture.limits(maximumCapabilities: 1)
        let decoder = JSONDecoder()
        decoder.userInfo[NestedTopologySnapshot.decodingLimitsUserInfoKey] = limits

        #expect(throws: NestedTopologyError.capabilityLimitExceeded(actual: 2, maximum: 1)) {
            try decoder.decode(NestedTopologySnapshot.self, from: oversized)
        }
    }

    @Test("decoding enforces the total node budget before decoding the next collection")
    func boundedTotalNodeDecoding() throws {
        let fixture = NestedTopologyTestFixture()
        let encoded = try JSONEncoder().encode(fixture.snapshot())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["agents"] = [NSNull()]
        let oversized = try JSONSerialization.data(withJSONObject: object)
        let limits = fixture.limits(maximumTotalNodes: 3)
        let decoder = JSONDecoder()
        decoder.userInfo[NestedTopologySnapshot.decodingLimitsUserInfoKey] = limits

        #expect(throws: NestedTopologyError.totalNodeLimitExceeded(actual: 4, maximum: 3)) {
            try decoder.decode(NestedTopologySnapshot.self, from: oversized)
        }
    }
}
