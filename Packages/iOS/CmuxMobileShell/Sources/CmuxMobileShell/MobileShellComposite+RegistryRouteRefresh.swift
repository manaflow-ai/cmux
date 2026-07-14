import CmuxMobilePairedMac
import Foundation
import os

private let registryRouteRefreshLog = Logger(
    subsystem: "com.cmuxterm.app",
    category: "MobileRegistryRouteRefresh"
)

@MainActor
extension MobileShellComposite {
    /// Refresh the active row only while its account, device, and authenticated
    /// instance authority still match the values captured before the network call.
    func refreshRoutesFromRegistry(
        for mac: MobilePairedMac,
        scope: MobileShellScopeSnapshot
    ) {
        guard let deviceRegistry, let pairedMacStore else { return }
        let macDeviceID = mac.macDeviceID
        let localRoutes = mac.routes
        let displayName = mac.displayName
        let capturedInstanceTag = mac.instanceTag
        let task = Task { [weak self] in
            let registryRoutes = await deviceRegistry.freshRoutes(
                forMacDeviceID: macDeviceID,
                instanceTag: capturedInstanceTag
            )
            guard let updated = DeviceRegistryService.selectReconnectRoutes(
                local: localRoutes,
                registry: registryRoutes
            ), let self else { return }
            await self.performSerializedPairedMacWrite(ifStillCurrent: nil) {
                guard await self.isScopeCurrent(scope),
                      await !self.isForgottenMacDeviceID(macDeviceID, scope: scope) else { return }
                let activeMac: MobilePairedMac?
                do {
                    activeMac = try await pairedMacStore.activeMac(
                        stackUserID: scope.userID,
                        teamID: scope.teamID
                    )
                } catch {
                    registryRouteRefreshLog.debug(
                        "registry refresh recheck failed: \(String(describing: error), privacy: .public)"
                    )
                    return
                }
                guard await self.isScopeCurrent(scope),
                      await !self.isForgottenMacDeviceID(macDeviceID, scope: scope),
                      DeviceRegistryService.shouldApplyRegistryRefresh(
                        isSignedIn: self.isSignedIn,
                        capturedUserID: scope.userID,
                        currentUserID: self.identityProvider?.currentUserID ?? scope.userID,
                        activeMacID: activeMac?.macDeviceID,
                        activeMacInstanceTag: activeMac?.instanceTag,
                        targetMacID: macDeviceID,
                        targetInstanceTag: capturedInstanceTag
                      ) else { return }
                do {
                    let wrote = try await pairedMacStore.upsertRoutesIfAuthorized(
                        macDeviceID: macDeviceID,
                        displayName: displayName,
                        routes: updated,
                        condition: .matchingInstanceTag(capturedInstanceTag),
                        markActive: nil,
                        stackUserID: scope.userID,
                        teamID: scope.teamID,
                        now: Date()
                    )
                    guard wrote else { return }
                } catch {
                    registryRouteRefreshLog.debug(
                        "registry refresh upsert failed: \(String(describing: error), privacy: .public)"
                    )
                    return
                }
                if await self.isForgottenMacDeviceID(macDeviceID, scope: scope) {
                    try? await pairedMacStore.remove(
                        macDeviceID: macDeviceID,
                        stackUserID: scope.userID,
                        teamID: scope.teamID
                    )
                    return
                }
                if await self.isScopeCurrent(scope) { await self.loadPairedMacs() }
            }
        }
        registryRouteRefreshTask = task
    }
}
