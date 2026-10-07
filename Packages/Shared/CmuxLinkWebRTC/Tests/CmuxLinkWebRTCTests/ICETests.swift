@testable import CmuxLinkWebRTC
import CmuxMobileWire
import Foundation
import Testing

@Suite("ICE configuration")
struct ICETests {
    @Test("TURN credentials decode from the A0 fixture result")
    func decodesFixture() throws {
        let url = repositoryRoot.appendingPathComponent("schemas/mobile-rpc/fixtures/signal.json")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try #require(root["cases"] as? [[String: Any]])
        let result = try #require(cases.first { ($0["phase"] as? String) == "result" }?["frame"] as? [String: Any])
        let frame = try JSONDecoder().decode(ReadResultFrame.self, from: JSONSerialization.data(withJSONObject: result))
        let configuration = try #require(TurnCredentialsDecoder().decode(frame.value))
        #expect(configuration.servers.count == 2)
        #expect(configuration.hasTURN)
        #expect(configuration.servers[1].username == "u-1791331800")
        #expect(configuration.expiresAt == Date(timeIntervalSince1970: 1_791_331_800))
    }

    @Test("non-ICE URLs are dropped and a malformed result is refused")
    func decodesDefensively() {
        let value = JSONValue.object([
            "ice_servers": .array([.object(["urls": .array([.string("https://evil"), .string("stun:stun.example:3478")])])]),
            "expires_at": .int(0),
        ])
        #expect(TurnCredentialsDecoder().decode(value)?.servers == [ICEServer(urls: ["stun:stun.example:3478"])])
        #expect(TurnCredentialsDecoder().decode(.object(["nope": .null])) == nil)
        #expect(ICEConfiguration.stunOnly.hasTURN == false)
    }

    @Test("the cache reuses credentials until 60 s before expiry")
    func cache() async throws {
        let clock = FakeNow()
        let provider = CountingProvider(expiry: Date(timeIntervalSince1970: 1000))
        let cache = ICEConfigurationCache(provider: provider, margin: 60, now: { clock.date })
        clock.date = Date(timeIntervalSince1970: 0)
        _ = try await cache.configuration(for: "h")
        _ = try await cache.configuration(for: "h")
        #expect(await provider.calls == 1)
        clock.date = Date(timeIntervalSince1970: 950)
        _ = try await cache.configuration(for: "h")
        #expect(await provider.calls == 2)
        _ = try await cache.configuration(for: "h", refresh: true)
        #expect(await provider.calls == 3)
    }
}

final class FakeNow: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 0)
}

actor CountingProvider: ICEServerProvider {
    let expiry: Date
    private(set) var calls = 0

    init(expiry: Date) {
        self.expiry = expiry
    }

    func iceConfiguration(for hostID: String) async throws -> ICEConfiguration {
        calls += 1
        return ICEConfiguration(servers: [ICEServer(urls: ["turn:t.example:3478"], username: "u", credential: "c")], expiresAt: expiry)
    }
}
