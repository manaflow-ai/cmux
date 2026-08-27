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
    func relayCredentialRequiresCanonicalURLTokenAndFutureRefresh() throws {
        #expect(throws: CmxIrohRelayConfigurationError.invalidURL) {
            try relay(url: "http://relay.example/", token: "aaaa")
        }
        #expect(throws: CmxIrohRelayConfigurationError.invalidURL) {
            try relay(url: "https://relay.example", token: "aaaa")
        }
        #expect(throws: CmxIrohRelayConfigurationError.invalidToken) {
            try relay(url: "https://relay.example/", token: "upperCASE")
        }
        #expect(
            try relay(url: "https://relay.example/", token: "aB_-.cD-_.eF_-").token
                == "aB_-.cD-_.eF_-"
        )
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

    @Test
    func customEndpointProfileExcludesManagedFallbackAndPreservesDirectPaths() throws {
        let custom = try CmxIrohCustomRelayProfile(
            relays: [
                CmxIrohCustomRelay(
                    url: "https://private.example.net:8443/",
                    authenticationToken: "private-token"
                ),
            ]
        )
        let profile = CmxIrohEndpointRelayProfile(customProfile: custom)
        let configuration = CmxIrohEndpointConfiguration(
            secretKey: try CmxIrohSecretKey(bytes: Data(repeating: 0, count: 32)),
            alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
            relayProfile: profile
        )

        #expect(configuration.relayProfile.allowedRelayURLs == [custom.relays[0].url])
        #expect(configuration.managedRelayURLs.isEmpty)
        #expect(configuration.relays.isEmpty)
    }

    @Test
    func bindPolicyDefaultsToEphemeralAndSerializesNumericStableAddresses() throws {
        let secret = try CmxIrohSecretKey(bytes: Data(repeating: 0, count: 32))
        let defaultConfiguration = try CmxIrohEndpointConfiguration(
            secretKey: secret,
            alpns: [],
            managedRelayURLs: [],
            relays: []
        )
        #expect(defaultConfiguration.bindPolicy == .ephemeral)
        #expect(defaultConfiguration.bindPolicy.socketAddress == nil)

        let ipv4 = try CmxIrohBindAddress(ipAddress: "0.0.0.0", port: 49_152)
        let ipv6 = try CmxIrohBindAddress(ipAddress: "::", port: 49_153)
        #expect(CmxIrohEndpointBindPolicy.required(ipv4).socketAddress == "0.0.0.0:49152")
        #expect(CmxIrohEndpointBindPolicy.required(ipv6).socketAddress == "[::]:49153")
        #expect(CmxIrohEndpointBindPolicy.preferred(ipv4).socketAddress == "0.0.0.0:49152")
        #expect(CmxIrohEndpointBindPolicy.preferred(ipv4).allowsEphemeralFallback)
        #expect(!CmxIrohEndpointBindPolicy.required(ipv4).allowsEphemeralFallback)
    }

    @Test
    func stableBindAddressRejectsEphemeralPortsAndNonNumericHosts() {
        #expect(throws: CmxIrohBindAddressError.zeroPort) {
            try CmxIrohBindAddress(ipAddress: "0.0.0.0", port: 0)
        }
        for value in [
            "mac.tailnet.ts.net",
            "[::]",
            "fe80::1%en0",
            "127.0.0.1\0ignored",
            " 127.0.0.1",
        ] {
            #expect(throws: CmxIrohBindAddressError.invalidIPAddress) {
                try CmxIrohBindAddress(ipAddress: value, port: 49_152)
            }
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
