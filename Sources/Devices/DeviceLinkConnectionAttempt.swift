import CMUXMobileCore
import CmuxSurfaceCatalogModel

/// Connects using the preferred route, then an explicitly authorized Tailscale
/// route if Iroh fails transiently. Each attempt re-reads the pairing grant.
/// The caller tears down the failed RPC client before returning an error.
@MainActor
enum DeviceLinkConnectionAttempt {
    static func connect<Connection>(
        routes: [CmxAttachRoute],
        instance: SurfaceDeviceInstanceID,
        hostName: String,
        selector: DeviceRouteSelector,
        grant: (CmxAttachRoute) -> CmxLegacyTailscaleAuthorizationEvidence?,
        connect: @MainActor (DeviceRouteSelector.Selection) async throws -> Connection
    ) async throws -> Connection {
        try Task.checkCancellation()
        let selection = try selector.select(from: routes, instance: instance, grant: grant)
        do {
            return try await connect(selection)
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
            return try await connect(fallback)
        }
    }
}
