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
    func managedEndpointConfigurationIsTokenlessAndBoundedBySize() throws {
        let secret = try CmxIrohSecretKey(bytes: Data(repeating: 0, count: 32))
        let configuration = try CmxIrohEndpointConfiguration(
            secretKey: secret,
            alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
            managedRelayURLs: ["https://relay.example/"]
        )
        #expect(configuration.relayProfile.activeRelays.map(\.url) == ["https://relay.example/"])
        #expect(configuration.relayProfile.activeRelays.allSatisfy {
            $0.authenticationToken == nil
        })

        let oversized = Set((0 ..< 17).map { "https://relay\($0).example/" })
        #expect(throws: CmxIrohEndpointConfigurationError.tooManyRelays(oversized.count)) {
            try CmxIrohEndpointConfiguration(
                secretKey: secret,
                alpns: [CmxIrohProtocolConfiguration.cmuxMobileV1.alpn],
                managedRelayURLs: oversized
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
    }

    @Test
    func bindPolicyDefaultsToEphemeralAndSerializesNumericStableAddresses() throws {
        let secret = try CmxIrohSecretKey(bytes: Data(repeating: 0, count: 32))
        let defaultConfiguration = try CmxIrohEndpointConfiguration(
            secretKey: secret,
            alpns: [],
            managedRelayURLs: []
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

}
