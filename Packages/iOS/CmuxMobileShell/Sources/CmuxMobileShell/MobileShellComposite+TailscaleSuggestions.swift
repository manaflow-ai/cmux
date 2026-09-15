import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

@MainActor
extension MobileShellComposite {
    /// Reads route hints from the already authenticated foreground connection.
    /// The host status response is identity checked before any address is shown.
    public func tailscaleRouteSuggestions(macDeviceID: String, instanceTag: String?) async -> [CmxAttachRoute] {
        guard let client = remoteClient,
              connectionState == .connected,
              let data = try? await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "mobile.host.status", params: [:]),
                timeoutNanoseconds: runtime?.pairingRequestTimeoutNanoseconds ?? 5_000_000_000
              ),
              let response = try? MobileHostStatusResponse.decode(data),
              response.macDeviceID == cmxCanonicalDeviceID(macDeviceID),
              response.macInstanceTag == instanceTag else { return [] }
        return MobileComputerRouteGroup.suggestions(response.routes)
            .flatMap(\.routes)
    }

    /// Adds the selected authenticated suggestions to one exact Computer.
    /// Existing Iroh and Tailscale grants are retained by the store transaction.
    @discardableResult
    public func acceptTailscaleRouteSuggestions(
        _ routes: [CmxAttachRoute], macDeviceID: String, instanceTag: String?
    ) async -> Bool {
        guard !routes.isEmpty, let pairedMacStore,
              let scope = await currentScopeSnapshot(),
              let mac = pairedMacsForIdentityMatching.first(where: {
                  $0.macDeviceID == macDeviceID && $0.instanceTag == instanceTag
              }) else { return false }
        do {
            try await pairedMacStore.authorizeUserTailscaleRoutes(
                macDeviceID: mac.macDeviceID, instanceTag: mac.instanceTag,
                stackUserID: mac.stackUserID ?? scope.userID, teamID: mac.teamID ?? scope.teamID,
                routes: routes, replacingExistingRoutes: false
            )
            guard await isScopeCurrent(scope) else { return false }
            await loadPairedMacs()
            return true
        } catch {
            return false
        }
    }
}
