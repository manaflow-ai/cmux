import CMUXMobileCore
import CmuxSurfaceCatalogModel

/// Establishes a transport using the preferred route or an authorized fallback,
/// then authenticates once. RPC failures after admission never select another
/// route: a generic closure can conceal a remote revocation.
@MainActor
struct DeviceLinkConnectionAttempt {
    let selector: DeviceRouteSelector

    func connect<Connection, Authenticated>(
        routes: [CmxAttachRoute],
        instance: SurfaceDeviceInstanceID,
        hostName: String,
        grant: (CmxAttachRoute) -> CmxLegacyTailscaleAuthorizationEvidence?,
        connect: @MainActor (DeviceRouteSelector.Selection) async throws -> Connection,
        authenticate: @MainActor (Connection) async throws -> Authenticated
    ) async throws -> Authenticated {
        try Task.checkCancellation()
        let selection = try selector.select(from: routes, instance: instance, grant: grant)
        let connection: Connection
        do {
            connection = try await connect(selection)
        } catch {
            try Task.checkCancellation()
            guard selection.route.kind == .iroh,
                  !(error is CancellationError),
                  DeviceLinkFailure.classify(error, hostName: hostName).isRetryable,
                  let fallback = try? selector.select(
                    from: routes.filter { $0.kind == .tailscale },
                    instance: instance,
                    grant: grant
                  ) else { throw error }
            connection = try await connect(fallback)
        }
        try Task.checkCancellation()
        return try await authenticate(connection)
    }
}
