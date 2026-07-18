import CmuxTerminalBackend
import Foundation
import Testing

@Suite("Backend identity and negotiation")
struct IdentifierAndHandshakeTests {
    @Test("strong UUID identities round trip as strings")
    func identifierRoundTrip() throws {
        let id = TerminalID(rawValue: UUID())
        let encoded = try JSONEncoder().encode(id)
        #expect(try JSONDecoder().decode(TerminalID.self, from: encoded) == id)
        #expect(String(data: encoded, encoding: .utf8) == "\"\(id.rawValue.uuidString)\"")
    }

    @Test("negotiation chooses the highest shared version")
    func overlappingProtocolRange() throws {
        let response = try identify(
            minimum: 7,
            maximum: 9,
            capabilities: ["stable-identities", "topology-deltas"]
        )
        let policy = BackendHandshakePolicy(
            supportedRange: 8 ... 10,
            requiredCapabilities: ["stable-identities", "topology-deltas"]
        )
        #expect(try policy.validate(response) == 9)
    }

    @Test("missing capability is rejected before state mutation")
    func missingCapability() throws {
        let response = try identify(minimum: 8, maximum: 8, capabilities: ["stable-identities"])
        let policy = BackendHandshakePolicy(
            supportedRange: 8 ... 8,
            requiredCapabilities: ["stable-identities", "topology-deltas"]
        )
        #expect(throws: BackendProtocolError.missingCapabilities(["topology-deltas"])) {
            try policy.validate(response)
        }
    }

    @Test("descending server protocol range is rejected without trapping")
    func descendingProtocolRange() throws {
        let response = try identify(
            minimum: 9,
            maximum: 8,
            capabilities: ["stable-identities"]
        )
        let policy = BackendHandshakePolicy(
            supportedRange: 8 ... 8,
            requiredCapabilities: ["stable-identities"]
        )

        #expect(throws: BackendProtocolError.malformedMessage) {
            try policy.validate(response)
        }
    }

    private func identify(
        minimum: UInt32,
        maximum: UInt32,
        capabilities: [String]
    ) throws -> BackendIdentifyResponse {
        let data = try encodedJSON([
            "app": "cmux-tui",
            "version": "0.1.0",
            "protocol": maximum,
            "protocol_min": minimum,
            "protocol_max": maximum,
            "capabilities": capabilities,
            "session": "main",
            "session_id": UUID().uuidString,
            "daemon_instance_id": UUID().uuidString,
            "topology_revision": 42,
            "pid": 123,
        ])
        return try JSONDecoder().decode(BackendIdentifyResponse.self, from: data)
    }
}
