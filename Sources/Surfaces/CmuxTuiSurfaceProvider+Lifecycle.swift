import CmuxCloud
import Foundation

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
    /// button can never bring the pane back. The stub does nothing yet.
    @discardableResult
    func wakeForReconnect(
        refreshFleet: @escaping @MainActor () async -> Void = {
            _ = await CmuxTuiSurfaceProviderRegistry.shared.refresh(force: true)
        }
    ) -> Task<Void, Never>? {
        nil
    }

    /// Retire synchronously, then join mutations before releasing shared transport access.
    func stop(stopReason: CloudTuiManualMirrorStopReason = .cloudUnavailable) async {
        suspendForFeatureFlag(stopReason: stopReason)
        await terminalMutationQueue.waitForIdle()
        await portAccessStore.remove(machineID: machineID)
    }

}
