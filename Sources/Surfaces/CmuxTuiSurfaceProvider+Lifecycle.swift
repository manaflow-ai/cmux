import CmuxCloud
import Foundation
import OSLog

@MainActor
extension CmuxTuiSurfaceProvider {
    var isAwake: Bool { summary.status == "running" }
    var providerID: String { summary.provider }
    /// Port rows are openable only when the machine advertises a preview
    /// capability or has the private route used by Freestyle.
    var capabilities: VMCapabilities { summary.capabilities }
    var supportsPortPreviews: Bool {
        capabilities.ports || summary.preferredPrivateAddress != nil
    }

    /// A person asked to reconnect a pane on a machine that is not running. Upkeep leaves such a
    /// machine asleep on purpose and a refresh stops at ``isAwake``, so without this the Reconnect
    /// button can never bring the pane back. A person's request wakes it as a direct open does
    /// (``CloudMachineLinkManager/connected(machineID:)`` resumes outside upkeep), then the fleet
    /// is re-read, so the provider learns the machine runs and its panes attach.
    @discardableResult
    func wakeForReconnect(
        refreshFleet: @escaping @MainActor () async -> Void = {
            _ = await CmuxTuiSurfaceProviderRegistry.shared.refresh(force: true)
        }
    ) -> Task<Void, Never>? {
        guard !isAwake, !hasLostAccess, summary.cloudSummary != nil else { return nil }
        let links = links, machineID = machineID
        // task-owner: one person's request; the link manager joins a resume already in flight and
        // the connect has its own deadline. A failed wake leaves the Reconnect card up.
        return Task { @MainActor in
            do {
                _ = try await links.connected(machineID: machineID)
            } catch {
                Logger(subsystem: "com.cmuxterm.app", category: "CloudVM")
                    .error("reconnect wake failed machine=\(machineID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            await refreshFleet()
        }
    }

    /// Retire synchronously, then join mutations before releasing shared transport access.
    func stop(stopReason: CloudTuiManualMirrorStopReason = .cloudUnavailable) async {
        suspendForFeatureFlag(stopReason: stopReason)
        await terminalMutationQueue.waitForIdle()
        await portAccessStore.remove(machineID: machineID)
    }

}
