import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohConfigurationTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test
    func endpointSecretRequiresExactlyThirtyTwoBytes() {
        #expect(throws: CmxIrohSecretKeyError.invalidByteCount(31)) {
            try CmxIrohSecretKey(bytes: Data(repeating: 0, count: 31))
        }
        #expect(throws: CmxIrohSecretKeyError.invalidByteCount(33)) {
            try CmxIrohSecretKey(bytes: Data(repeating: 0, count: 33))
        }
    }

    @Test
    func relayCredentialRequiresCanonicalURLBase32AndFutureRefresh() throws {
        #expect(throws: CmxIrohRelayConfigurationError.invalidURL) {
            try relay(url: "http://relay.example/", token: "aaaa")
        }
        #expect(throws: CmxIrohRelayConfigurationError.invalidURL) {
            try relay(url: "https://relay.example", token: "aaaa")
        }
        #expect(throws: CmxIrohRelayConfigurationError.invalidToken) {
            try relay(url: "https://relay.example/", token: "upperCASE")
        }
        #expect(throws: CmxIrohRelayConfigurationError.invalidLifetime) {
            try CmxIrohRelayConfiguration(
                url: "https://relay.example/",
                token: "aaaa",
                expiresAt: now.addingTimeInterval(10),
                refreshAfter: now,
                now: now
            )
        }
    }

    @Test
    func endpointConfigurationRejectsUnmanagedAndDuplicateRelays() throws {
        let relay = try relay(url: "https://relay.example/", token: "aaaa")
        let secret = try CmxIrohSecretKey(bytes: Data(repeating: 0, count: 32))

        #expect(throws: CmxIrohEndpointConfigurationError.unmanagedRelayURL(relay.url)) {
            try CmxIrohEndpointConfiguration(
                secretKey: secret,
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: [],
                relays: [relay]
            )
        }
        #expect(throws: CmxIrohEndpointConfigurationError.duplicateRelayURL(relay.url)) {
            try CmxIrohEndpointConfiguration(
                secretKey: secret,
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: [relay.url],
                relays: [relay, relay]
            )
        }
    }

    private func relay(
        url: String,
        token: String
    ) throws -> CmxIrohRelayConfiguration {
        try CmxIrohRelayConfiguration(
            url: url,
            token: token,
            expiresAt: now.addingTimeInterval(24 * 60 * 60),
            refreshAfter: now.addingTimeInterval(12 * 60 * 60),
            now: now
        )
    }
}
