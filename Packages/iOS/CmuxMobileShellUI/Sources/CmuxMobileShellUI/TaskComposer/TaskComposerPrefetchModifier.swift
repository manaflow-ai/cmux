import CmuxMobileShell
import SwiftUI

/// Keeps connection observations out of the root view's rendering dependencies.
struct TaskComposerPrefetchModifier: ViewModifier {
    let store: CMUXMobileShellStore
    @Environment(\.scenePhase) private var scenePhase

    private var prefetchTaskID: String {
        [
            scenePhase == .active ? "active" : "inactive",
            String(store.workspaceTopologyVersion),
            store.connectionState == .connected ? "connected" : "disconnected",
            store.connectedMacDeviceID ?? "",
            store.connectedMacInstanceTag ?? "",
        ].joined(separator: "\u{1F}")
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
