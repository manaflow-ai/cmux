import Foundation
import Testing
@testable import CmuxNextDaemon

struct AgentInventoryRequestTests {
    @Test func oldOwnersAreRefusedBeforeRequestEncoding() throws {
        for capabilities in [[], ["agent-inventory"], ["agent-inventory-v10"]] {
            let identity = DaemonIdentity(capabilities: capabilities, generation: DaemonGeneration(rawValue: "inventory-test"))
            do {
                try AgentInventoryRequest.requireServed(by: identity)
                Issue.record("an unsupported owner passed the request admission gate")
            } catch DaemonError.missingCapabilities(let missing) {
                #expect(missing == ["agent-inventory-v1"])
            }
        }
    }

    @Test func supportedOwnersSendNoSelectorsOrControls() throws {
        let identity = DaemonIdentity(capabilities: ["agent-inventory-v1"], generation: DaemonGeneration(rawValue: "inventory-test"))
        try AgentInventoryRequest.requireServed(by: identity)
        let data = try WireCoding.encodeRequest(AgentInventoryRequest(), id: 7)
        let fields = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(fields == .object(["id": .number(7), "cmd": .string("agent-inventory")]))
    }

    @Test func ownerObservationsDecodeThroughTheDaemonEnvelope() throws {
        let data = Data(#"{"id":7,"ok":true,"data":{"view":"inventory","cached":true,"harnesses":[{"id":"claude","channel":"launcher","version":null,"latest":null,"latestCheckedAt":null,"outdated":false,"auth":"unknown","checkedAt":123}]}}"#.utf8)
        let result = try WireCoding.decodeResponse(AgentInventoryRequest.Response.self, from: data)
        let row = try #require(result.harnesses.first)
        #expect(row.id == "claude")
        #expect(row.family == nil)
        #expect(row.channel == .launcher)
        #expect(row.auth == .unknown)
        #expect(row.version == nil)
        #expect(row.checkedAt == 123)
    }

    @Test func familyEvidenceIsDistinctFromTheProfileID() throws {
        let data = Data(#"{"id":7,"ok":true,"data":{"view":"inventory","cached":true,"harnesses":[{"id":"codex","family":"claude","channel":"native","version":"1.2.3","latest":null,"latestCheckedAt":null,"outdated":false,"auth":"unknown","checkedAt":123}]}}"#.utf8)
        let result = try WireCoding.decodeResponse(AgentInventoryRequest.Response.self, from: data)
        let row = try #require(result.harnesses.first)
        #expect(row.id == "codex")
        #expect(row.family == .claude)
    }

    @Test func futureFamilyStringsRemainUnknownAndNonStringsAreRefused() throws {
        let unknown = try JSONDecoder().decode(AgentCLIFamily.self, from: Data(#""private-future-family""#.utf8))
        #expect(unknown == .unknown)
        #expect(unknown.rawValue == "unknown")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentCLIFamily.self, from: Data("true".utf8))
        }
    }
}
