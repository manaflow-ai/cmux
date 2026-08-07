import Foundation
import Testing
@testable import CmuxNestedTopology

@Suite("Nested node identity")
struct NestedNodeIDTests {
    @Test("identical raw IDs from separate provider instances never collide")
    func providerInstanceCollisionResistance() {
        let first = NestedTopologyTestFixture(
            instanceRawValue: "server-a",
            generation: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let second = NestedTopologyTestFixture(
            instanceRawValue: "server-b",
            generation: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )

        #expect(first.id("pane-1", kind: .pane) != second.id("pane-1", kind: .pane))
        #expect(Set([
            first.id("pane-1", kind: .pane),
            second.id("pane-1", kind: .pane),
        ]).count == 2)
    }

    @Test("reconnect generations invalidate node identity")
    func reconnectGenerationIsolation() {
        let first = NestedTopologyTestFixture(
            generation: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let reconnected = NestedTopologyTestFixture(
            generation: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )

        #expect(first.id("pane-1", kind: .pane) != reconnected.id("pane-1", kind: .pane))
    }

    @Test("the same provider raw ID is distinct at every topology level")
    func nodeKindCollisionResistance() {
        let fixture = NestedTopologyTestFixture()
        let ids = Set(NestedNodeKind.allCases.map { fixture.id("shared", kind: $0) })

        #expect(ids.count == NestedNodeKind.allCases.count)
    }

    @Test("identical raw IDs at every level coexist in one validated snapshot")
    func nodeKindCollisionResistanceInSnapshot() throws {
        let fixture = NestedTopologyTestFixture()
        let snapshot = try fixture.snapshot(
            workspaces: [fixture.workspace("shared")],
            tabs: [fixture.tab("shared", workspaceRawID: "shared")],
            panes: [fixture.pane("shared", tabRawID: "shared")],
            agents: [fixture.agent("shared", paneRawID: "shared")]
        )

        #expect(snapshot.workspaces[0].id.rawID == "shared")
        #expect(snapshot.tabs[0].id.rawID == "shared")
        #expect(snapshot.panes[0].id.rawID == "shared")
        #expect(snapshot.agents[0].id.rawID == "shared")
    }

    @Test("opaque provider IDs retain delimiter-like content")
    func opaqueRawIDRoundTrip() throws {
        let fixture = NestedTopologyTestFixture()
        let original = fixture.id("workspace:one/pane\u{0}token", kind: .pane)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NestedNodeID.self, from: data)

        #expect(decoded == original)
        #expect(decoded.rawID == "workspace:one/pane\u{0}token")
    }

    @Test("serialized identity is structured and explicitly versioned")
    func structuredEncoding() throws {
        let id = NestedTopologyTestFixture().id("pane:17", kind: .pane)
        let data = try JSONEncoder().encode(id)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providerKind = try #require(object["providerKind"] as? String)
        let rawID = try #require(object["rawID"] as? String)

        #expect(object["version"] as? Int == Int(NestedNodeID.currentVersion))
        #expect(providerKind.hasPrefix("cmux-utf8-v1:"))
        #expect(rawID.hasPrefix("cmux-utf8-v1:"))
        #expect(object["kind"] as? String == "pane")
        #expect(object["providerInstanceID"] is [String: Any])
    }

    @Test("malformed opaque wire values fail closed", arguments: [
        "pane:17",
        "cmux-utf8-v1:/w==",
    ])
    func rejectsMalformedOpaqueWireValue(_ wireValue: String) throws {
        let id = NestedTopologyTestFixture().id("pane:17", kind: .pane)
        let data = try JSONEncoder().encode(id)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["rawID"] = wireValue
        let malformed = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NestedNodeID.self, from: malformed)
        }
    }

    @Test("opaque identity components preserve exact canonically equivalent UTF-8")
    func exactUTF8Identity() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        #expect(composed == decomposed)

        let fixture = NestedTopologyTestFixture()
        let composedID = fixture.id(composed, kind: .workspace)
        let decomposedID = fixture.id(decomposed, kind: .workspace)
        let snapshot = try fixture.snapshot(
            capabilities: NestedProviderCapabilities([]),
            workspaces: [
                fixture.workspace(composed, order: 0, title: nil),
                fixture.workspace(decomposed, order: 0, title: nil),
            ],
            tabs: [],
            panes: [],
            agents: []
        )

        #expect(composedID != decomposedID)
        #expect(Set([composedID, decomposedID]).count == 2)
        #expect(snapshot.workspaces.count == 2)

        let generation = fixture.provider.instanceID.generation
        let composedProvider = NestedProviderIdentity(
            kind: .herdr,
            instanceID: NestedProviderInstanceID(rawValue: composed, generation: generation)
        )
        let decomposedProvider = NestedProviderIdentity(
            kind: .herdr,
            instanceID: NestedProviderInstanceID(rawValue: decomposed, generation: generation)
        )
        #expect(composedProvider != decomposedProvider)

        let paneID = fixture.id("pane-1", kind: .pane)
        let composedSession = NestedAssociationKey(paneID: paneID, sessionID: composed)
        let decomposedSession = NestedAssociationKey(paneID: paneID, sessionID: decomposed)
        #expect(composedSession != decomposedSession)
    }
}
