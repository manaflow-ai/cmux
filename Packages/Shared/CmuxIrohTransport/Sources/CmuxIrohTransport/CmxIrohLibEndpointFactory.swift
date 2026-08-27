public import CMUXMobileCore
import Foundation
public import IrohLib

/// Production endpoint factory using the forked Iroh Swift bindings.
public struct CmxIrohLibEndpointFactory: CmxIrohEndpointFactory {
    private let transportVerificationMode: CmxIrohTransportVerificationMode
    private let addressLookup: (any AddressLookupService)?

    /// Creates an endpoint factory with an optional debug transport constraint.
    ///
    /// - Parameters:
    ///   - transportVerificationMode: The path class the endpoint may use.
    ///   - addressLookup: An optional custom discovery service installed on
    ///     every endpoint this factory binds. Nil (the default) leaves the
    ///     bind options byte-identical to a build without the lookup; hint
    ///     dials are unaffected either way (magicsock merges lookup results
    ///     as `Source::AddressLookup` next to `Source::App` hints).
    public init(
        transportVerificationMode: CmxIrohTransportVerificationMode = .automatic,
        addressLookup: (any AddressLookupService)? = nil
    ) {
        self.transportVerificationMode = transportVerificationMode
        self.addressLookup = addressLookup
    }

    public func bind(
        configuration: CmxIrohEndpointConfiguration
    ) async throws -> any CmxIrohEndpoint {
        let driver: Endpoint
        do {
            driver = try await bindDriver(
                configuration: configuration,
                socketAddress: configuration.bindPolicy.socketAddress
            )
        } catch where configuration.bindPolicy.allowsEphemeralFallback {
            driver = try await bindDriver(
                configuration: configuration,
                socketAddress: nil
            )
        }
        let identity = try CmxIrohLibIdentity.peerIdentity(driver.id())
        let endpoint = CmxIrohLibEndpoint(
            driver: driver,
            identity: identity,
            configuration: configuration,
            transportVerificationMode: transportVerificationMode
        )
        await endpoint.startMonitoring()
        return endpoint
    }

    private func bindDriver(
        configuration: CmxIrohEndpointConfiguration,
        socketAddress: String?
    ) async throws -> Endpoint {
        let relayMap = RelayMap.empty()
        if transportVerificationMode != .directOnly {
            for relay in configuration.relayProfile.activeRelays {
                try relayMap.insert(config: CmxIrohLibEndpoint.relayConfig(relay))
            }
        }
        let options = Self.endpointOptions(
            configuration: configuration,
            socketAddress: socketAddress,
            relayMap: relayMap,
            transportVerificationMode: transportVerificationMode,
            addressLookup: addressLookup
        )
        return try await Endpoint.bind(options: options)
    }

    static func endpointOptions(
        configuration: CmxIrohEndpointConfiguration,
        socketAddress: String?,
        relayMap: RelayMap,
        transportVerificationMode: CmxIrohTransportVerificationMode = .automatic,
        addressLookup: (any AddressLookupService)? = nil
    ) -> EndpointOptions {
        EndpointOptions(
            preset: presetMinimal(),
            bindAddr: socketAddress,
            secretKey: configuration.secretKey.bytes,
            alpns: configuration.alpns,
            relayMode: transportVerificationMode == .directOnly
                ? RelayMode.disabled()
                : RelayMode.custom(map: relayMap),
            addressLookup: addressLookup,
            portMappingEnabled: false,
            deferNatTraversalUntilAuthorized: true,
            initialMaxConcurrentBiStreams: 0,
            initialMaxConcurrentUniStreams: 0
        )
    }
}
