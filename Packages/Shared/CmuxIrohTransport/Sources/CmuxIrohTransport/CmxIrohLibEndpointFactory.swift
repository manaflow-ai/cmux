public import CMUXMobileCore
import Foundation
public import IrohLib

/// Production endpoint factory using the forked Iroh Swift bindings.
public struct CmxIrohLibEndpointFactory: CmxIrohEndpointFactory {
    private let transportVerificationMode: CmxIrohTransportVerificationMode

    /// Creates an endpoint factory with an optional debug transport constraint.
    ///
    /// - Parameter transportVerificationMode: The path class the endpoint may use.
    public init(
        transportVerificationMode: CmxIrohTransportVerificationMode = .automatic
    ) {
        self.transportVerificationMode = transportVerificationMode
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
            transportVerificationMode: transportVerificationMode
        )
        return try await Endpoint.bind(options: options)
    }

    static func endpointOptions(
        configuration: CmxIrohEndpointConfiguration,
        socketAddress: String?,
        relayMap: RelayMap,
        transportVerificationMode: CmxIrohTransportVerificationMode = .automatic
    ) -> EndpointOptions {
        EndpointOptions(
            preset: presetMinimal(),
            bindAddr: socketAddress,
            secretKey: configuration.secretKey.bytes,
            alpns: configuration.alpns,
            relayMode: transportVerificationMode == .directOnly
                ? RelayMode.disabled()
                : RelayMode.custom(map: relayMap),
            portMappingEnabled: false,
            deferNatTraversalUntilAuthorized: true,
            initialMaxConcurrentBiStreams: 0,
            initialMaxConcurrentUniStreams: 0
        )
    }
}

extension CmxIrohLibEndpointFactory {
    /// Wraps a QUIC connection accepted by a foreign endpoint owner so the
    /// legacy dialect can be served over it (dual-ALPN compatibility: one
    /// endpoint/identity, old protocol for old peers).
    public static func adoptAcceptedConnection(
        _ driver: Connection
    ) throws -> any CmxIrohConnection {
        try CmxIrohLibConnection(driver: driver)
    }
}
