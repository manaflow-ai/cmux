import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

@MainActor
extension MobileShellComposite {
    /// Removes one user-controlled route from one exact Mac/build pairing.
    /// Iroh is the permanent identity route and cannot be removed.
    public func removeRoute(
        _ route: CmxAttachRoute,
        macDeviceID: String,
        instanceTag: String?
    ) async {
        guard route.kind != .iroh,
              let scope = await currentScopeSnapshot(),
              let pairedMacStore,
              let mac = pairedMacsForIdentityMatching.first(where: {
                  $0.macDeviceID == macDeviceID && $0.instanceTag == instanceTag
              }) else { return }

        let routes = mac.routes.filter { $0.id != route.id }
        guard routes.count != mac.routes.count else { return }
        do {
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
            guard wrote, await isScopeCurrent(scope) else { return }
            await loadPairedMacs()
            await loadRegistryDevices()
        } catch {
            // Keep the authoritative row unchanged when the scoped write fails.
        }
    }
}
