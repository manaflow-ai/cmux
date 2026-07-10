import Foundation
import IrohLib

/// Production endpoint factory using the forked Iroh Swift bindings.
public struct CmxIrohLibEndpointFactory: CmxIrohEndpointFactory {
    public init() {}

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
            configuration: configuration
        )
        await endpoint.startMonitoring()
        return endpoint
    }

    private func bindDriver(
        configuration: CmxIrohEndpointConfiguration,
        socketAddress: String?
    ) async throws -> Endpoint {
        let relayMap = RelayMap.empty()
        let now = Date()
        for relay in configuration.relays {
            guard relay.expiresAt > now else {
                throw CmxIrohLibError.expiredRelayCredential(relay.url)
            }
            try relayMap.insert(config: CmxIrohLibEndpoint.relayConfig(relay))
        }
        let options = Self.endpointOptions(
            configuration: configuration,
            socketAddress: socketAddress,
            relayMap: relayMap
        )
        return try await Endpoint.bind(options: options)
    }

    static func endpointOptions(
        configuration: CmxIrohEndpointConfiguration,
        socketAddress: String?,
        relayMap: RelayMap
    ) -> EndpointOptions {
        EndpointOptions(
            preset: presetMinimal(),
            bindAddr: socketAddress,
            secretKey: configuration.secretKey.bytes,
            alpns: configuration.alpns,
            relayMode: RelayMode.custom(map: relayMap),
            portMappingEnabled: false,
            deferNatTraversalUntilAuthorized: true,
            initialMaxConcurrentBiStreams: 0,
            initialMaxConcurrentUniStreams: 0
        )
    }
}
