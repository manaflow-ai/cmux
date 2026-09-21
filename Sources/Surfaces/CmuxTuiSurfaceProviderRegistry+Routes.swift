import CmuxSettings
import Foundation

/// Routes Cloud traffic through the current account-owned registry.
extension CmuxTuiSurfaceProviderRegistry {
    /// The headless link's local mux socket for a machine, connecting if needed.
    func linkSocketPath(machineID: String) async throws -> (socketPath: String, session: String) {
        guard !isRetired, !ManagedDevicePolicy().isEnforced(.disableCloud), isCloudEnabled(), !Task.isCancelled else {
            throw CloudMachineLinkManager.ManagerError.retryLater(String(
                localized: "cloud.feature.disabled",
                defaultValue: "Cloud Machines are temporarily unavailable."
            ))
        }
        let epoch = accessEpoch
        let connected = try await links.connected(machineID: machineID)
        guard !isRetired, epoch == accessEpoch,
              !ManagedDevicePolicy().isEnforced(.disableCloud), isCloudEnabled(), !Task.isCancelled else {
            throw CancellationError()
        }
        return (connected.socketPath, connected.session)
    }

    func privateRoute(machineID: String) async -> String? {
        guard !isRetired, !ManagedDevicePolicy().isEnforced(.disableCloud), isCloudEnabled(), !Task.isCancelled else {
            return nil
        }
        let epoch = accessEpoch
        // The persisted device marker outlives this in-memory registry. An
        // explicit open must discover its machine before using the saved-device
        // shortcut, even when the first background fleet read has not run.
        guard await providerRefreshingIfMissing(machineID: machineID) != nil else { return nil }
        let route = await links.privateRoute(for: machineID)
        guard !isRetired, epoch == accessEpoch, isCloudEnabled(), !Task.isCancelled else { return nil }
        return route
    }

    func resolvedPrivateRoute(machineID: String, through hub: CloudWireGuardHub.Ready, fallbackRoute: String, addresses: [String]) async throws -> String {
        guard !isRetired, !ManagedDevicePolicy().isEnforced(.disableCloud), isCloudEnabled(), !Task.isCancelled else {
            throw CloudMachineLinkManager.ManagerError.retryLater(String(
                localized: "cloud.feature.disabled",
                defaultValue: "Cloud Machines are temporarily unavailable."
            ))
        }
        let epoch = accessEpoch
        let route = try await links.resolvedPrivateRoute(machineID: machineID, through: hub, fallbackRoute: fallbackRoute, addresses: addresses)
        guard !isRetired, epoch == accessEpoch,
              !ManagedDevicePolicy().isEnforced(.disableCloud), isCloudEnabled(), !Task.isCancelled else {
            throw CancellationError()
        }
        return route
    }

}
