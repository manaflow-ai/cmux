import Foundation
import IrohLib
import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohDebugAddressLookupFlagTests {
    @Test("flag defaults to off")
    func defaultsToOff() {
        #expect(!CmxIrohDebugAddressLookupFlag.isEnabled(rawValue: nil))
        #expect(!CmxIrohDebugAddressLookupFlag.isEnabled(rawValue: ""))
        #expect(!CmxIrohDebugAddressLookupFlag.isEnabled(rawValue: "0"))
        #expect(!CmxIrohDebugAddressLookupFlag.isEnabled(rawValue: "false"))
        #expect(!CmxIrohDebugAddressLookupFlag.isEnabled(rawValue: "off"))
        #expect(!CmxIrohDebugAddressLookupFlag.isEnabled(rawValue: "banana"))
    }

    @Test("explicit opt-ins enable the flag")
    func explicitOptInsEnable() {
        #expect(CmxIrohDebugAddressLookupFlag.isEnabled(rawValue: "1"))
        #expect(CmxIrohDebugAddressLookupFlag.isEnabled(rawValue: "true"))
        #expect(CmxIrohDebugAddressLookupFlag.isEnabled(rawValue: "on"))
        #expect(CmxIrohDebugAddressLookupFlag.isEnabled(rawValue: " YES "))
    }

    @Test("environment value wins over defaults")
    func environmentWins() {
        let defaults = UserDefaults(
            suiteName: "CmxIrohDebugAddressLookupFlagTests"
        )!
        defaults.set("1", forKey: CmxIrohDebugAddressLookupFlag.key)
        defer { defaults.removeObject(forKey: CmxIrohDebugAddressLookupFlag.key) }

        #expect(CmxIrohDebugAddressLookupFlag.rawValue(
            environment: [CmxIrohDebugAddressLookupFlag.key: "0"],
            defaults: defaults
        ) == "0")
        #expect(CmxIrohDebugAddressLookupFlag.rawValue(
            environment: [:],
            defaults: defaults
        ) == "1")
    }

    @Test("flag off binds with byte-identical endpoint options (no lookup)")
    func flagOffLeavesEndpointOptionsUnchanged() throws {
        let configuration = CmxIrohEndpointConfiguration(
            secretKey: try CmxIrohSecretKey(bytes: SecretKey.generate().toBytes()),
            alpns: [Data("cmux/mobile/1".utf8)],
            relayProfile: try CmxIrohEndpointRelayProfile(managedRelayURLs: [])
        )

        let withoutLookup = CmxIrohLibEndpointFactory.endpointOptions(
            configuration: configuration,
            socketAddress: nil,
            relayMap: RelayMap.empty()
        )
        #expect(withoutLookup.addressLookup == nil)

        let broker = NoopRecordBroker()
        let lookup = CmxIrohRegistryAddressLookup(
            broker: broker,
            allowedRelayURLs: { [] }
        )
        let withLookup = CmxIrohLibEndpointFactory.endpointOptions(
            configuration: configuration,
            socketAddress: nil,
            relayMap: RelayMap.empty(),
            addressLookup: lookup
        )
        #expect(withLookup.addressLookup === lookup)

        // The remaining options are identical either way: the lookup slot is
        // the only difference between flag-on and flag-off binds.
        #expect(withoutLookup.bindAddr == withLookup.bindAddr)
        #expect(withoutLookup.secretKey == withLookup.secretKey)
        #expect(withoutLookup.alpns == withLookup.alpns)
        #expect(withoutLookup.portMappingEnabled == withLookup.portMappingEnabled)
        #expect(
            withoutLookup.deferNatTraversalUntilAuthorized
                == withLookup.deferNatTraversalUntilAuthorized
        )
        #expect(
            withoutLookup.initialMaxConcurrentBiStreams
                == withLookup.initialMaxConcurrentBiStreams
        )
        #expect(
            withoutLookup.initialMaxConcurrentUniStreams
                == withLookup.initialMaxConcurrentUniStreams
        )
    }
}

private struct NoopRecordBroker: CmxIrohEndpointRecordBroker {
    func fetchEndpointRecords() async throws -> [Data] { [] }
    func publishEndpointRecord(_: Data) async throws {}
}
