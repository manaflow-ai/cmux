import Foundation
import IrohLib

/// Production endpoint factory using the forked Iroh Swift bindings.
public struct CmxIrohLibEndpointFactory: CmxIrohEndpointFactory {
    public init() {}

    public func bind(
        configuration: CmxIrohEndpointConfiguration
    ) async throws -> any CmxIrohEndpoint {
        let relayMap = RelayMap.empty()
        let now = Date()
        for relay in configuration.relays {
            guard relay.expiresAt > now else {
                throw CmxIrohLibError.expiredRelayCredential(relay.url)
            }
            try relayMap.insert(config: CmxIrohLibEndpoint.relayConfig(relay))
        }
        let options = EndpointOptions(
            preset: presetMinimal(),
            bindAddr: configuration.bindPolicy.socketAddress,
            secretKey: configuration.secretKey.bytes,
            alpns: configuration.alpns,
            relayMode: RelayMode.custom(map: relayMap)
        )
        let driver = try await Endpoint.bind(options: options)
        let identity = try CmxIrohLibIdentity.peerIdentity(driver.id())
        let endpoint = CmxIrohLibEndpoint(
            driver: driver,
            identity: identity,
            configuration: configuration
        )
        await endpoint.startMonitoring()
        return endpoint
    }
}
