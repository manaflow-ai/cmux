public import CMUXMobileCore
public import CmuxMobilePairedMac
import Foundation

@MainActor
extension MobileShellComposite {
    /// Removes one user-controlled route from one exact Mac/build pairing.
    /// Iroh is the permanent identity route and cannot be removed.
    @discardableResult
    public func removeRoute(
        _ route: CmxAttachRoute,
        macDeviceID: String,
        instanceTag: String?,
        deleteComputerIfLastRoute: Bool = false
    ) async -> Bool {
        guard route.kind != .iroh,
              let scope = await currentScopeSnapshot(),
              let pairedMacStore,
              let mac = pairedMacsForIdentityMatching.first(where: {
                  $0.macDeviceID == macDeviceID && $0.instanceTag == instanceTag
              }) else { return false }

        let routes = mac.routes.filter { $0.id != route.id }
        guard routes.count != mac.routes.count else { return false }
        do {
            if routes.isEmpty {
                guard deleteComputerIfLastRoute else { return false }
                try await pairedMacStore.removeExactScope(
                    macDeviceID: mac.macDeviceID,
                    instanceTag: mac.instanceTag,
                    stackUserID: mac.stackUserID ?? scope.userID,
                    teamID: mac.teamID
                )
            } else {
                let wrote = try await pairedMacStore.upsertRoutesIfAuthorized(
                    macDeviceID: mac.macDeviceID,
                    displayName: mac.displayName,
                    routes: routes,
                    condition: .matchingInstanceTag(mac.instanceTag),
                    markActive: nil,
                    stackUserID: mac.stackUserID ?? scope.userID,
                    teamID: mac.teamID,
                    now: Date()
                )
                guard wrote else { return false }
            }
            guard await isScopeCurrent(scope) else { return false }
            await loadPairedMacs()
            await loadRegistryDevices()
            return true
        } catch {
            // Keep the authoritative row unchanged when the scoped write fails.
            return false
        }
    }
}
