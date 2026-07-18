import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

/// Routing target for a workspace mutation in the aggregated multi-Mac list.
struct WorkspaceMutationTarget {
    let client: MobileCoreRPCClient?
    let isForeground: Bool
    let macDeviceID: String?
}

extension MobileShellComposite {
    /// Revalidates the exact owner/client captured by a workspace action.
    /// Foreground operations also retain the connection generation; secondary
    /// operations retain their per-Mac subscription identity through its client.
    func isCurrentWorkspaceMutationTarget(
        _ target: WorkspaceMutationTarget,
        client: MobileCoreRPCClient,
        generation: UUID
    ) -> Bool {
        guard target.client === client else { return false }
        if target.isForeground {
            return isCurrentRemoteOperation(client: client, generation: generation)
        }
        guard let macDeviceID = target.macDeviceID else { return false }
        return secondaryMacSubscriptions[macDeviceID]?.client === client
    }

    /// Authorization failure invalidates only the connection that rejected the
    /// request. A secondary-Mac failure must never tear down foreground state.
    func invalidateWorkspaceMutationTargetForAuthorizationFailure(
        _ error: any Error,
        target: WorkspaceMutationTarget,
        client: MobileCoreRPCClient,
        generation: UUID
    ) -> Bool {
        guard Self.shouldDisconnectForAuthorizationFailure(error) else { return false }
        // Treat a stale authorization result as handled without touching the
        // replacement owner. Callers revalidate separately to suppress stale UI.
        guard isCurrentWorkspaceMutationTarget(
            target,
            client: client,
            generation: generation
        ) else { return true }
        if target.isForeground {
            return disconnectForAuthorizationFailureIfNeeded(error)
        }
        guard let macDeviceID = target.macDeviceID,
              let subscription = secondaryMacSubscriptions[macDeviceID],
              subscription.client === client else { return true }
        subscription.cancel()
        secondaryMacSubscriptions[macDeviceID] = nil
        markSecondaryMacUnavailable(macDeviceID)
        return true
    }
}
