import CMUXMobileCore
import CmuxSurfaceCatalogModel

/// Connects using the preferred route. The caller owns one route's RPC
/// handshake and tears its client down before propagating a failure.
@MainActor
enum DeviceLinkConnectionAttempt {
    static func connect<Connection>(
        routes: [CmxAttachRoute],
        instance: SurfaceDeviceInstanceID,
        hostName: String,
        selector: DeviceRouteSelector,
        grant: (CmxAttachRoute) -> CmxLegacyTailscaleAuthorizationEvidence?,
        connect: (DeviceRouteSelector.Selection) async throws -> Connection
    ) async throws -> Connection {
        try Task.checkCancellation()
        let selection = try selector.select(from: routes, instance: instance, grant: grant)
        return try await connect(selection)
    }
}
