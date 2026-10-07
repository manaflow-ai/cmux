import CmuxLinkWebRTC
import CmuxMobileHost
import CmuxMobileWire
@testable import CmuxNextMobileConnect
import Testing

@Suite("Host socket ICE servers")
struct HostSocketICEServersTests {
    @Test func turnCredentialsFromTheHostSocket() async throws {
        let provider = HostSocketICEServers { op, params in
            #expect(op == "signal.turn_credentials")
            #expect(params["host"] == "host_1")
            return ReadResultFrame(id: 1, value: [
                "ice_servers": [["urls": ["turn:turn.example:3478?transport=udp"], "username": "u", "credential": "c"]],
                "expires_at": 1_900_000_000_000,
            ], revision: "0")
        }
        let configuration = try await provider.iceConfiguration(for: "host_1")
        #expect(configuration.servers.first?.urls == ["turn:turn.example:3478?transport=udp"])
        #expect(configuration.servers.first?.username == "u")
        #expect(configuration.expiresAt != nil)
    }

    @Test func turnUnavailableOrNoSocketDegradesToStun() async throws {
        let refused = HostSocketICEServers { _, _ in
            throw HostControlUplinkError(code: "signal.turn_unavailable", message: "no TURN")
        }
        #expect(try await refused.iceConfiguration(for: "host_1") == .stunOnly)
        let garbled = HostSocketICEServers { _, _ in ReadResultFrame(id: 1, value: "nope", revision: "0") }
        #expect(try await garbled.iceConfiguration(for: "host_1") == .stunOnly)
    }
}
