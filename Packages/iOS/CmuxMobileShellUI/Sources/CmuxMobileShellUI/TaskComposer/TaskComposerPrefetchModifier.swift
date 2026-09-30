import CmuxMobileShell
import SwiftUI

/// Keeps connection observations out of the root view's rendering dependencies.
struct TaskComposerPrefetchModifier: ViewModifier {
    let store: CMUXMobileShellStore
    @Environment(\.scenePhase) private var scenePhase

    private struct PrefetchTaskID: Equatable {
        let scenePhase: ScenePhase
        let workspaceTopologyVersion: UInt64
        let connectionState: MobileConnectionState
        let connectedMacPairingID: String
    }

    private var prefetchTaskID: PrefetchTaskID {
        PrefetchTaskID(
            scenePhase: scenePhase,
            workspaceTopologyVersion: store.workspaceTopologyVersion,
            connectionState: store.connectionState,
            connectedMacPairingID: [
                store.connectedMacDeviceID ?? "",
                store.connectedMacInstanceTag ?? "",
            ].joined(separator: "\u{1F}")
        )
    }

    func body(content: Content) -> some View {
        content.task(id: prefetchTaskID) {
            guard scenePhase == .active else { return }
            // Build the paired-Mac target snapshot once when the task starts.
            // Unrelated SwiftUI body passes never scan or sort the Mac list.
            await store.prefetchTaskModels(for: store.taskModelPrefetchTargets)
        }
    }
}
