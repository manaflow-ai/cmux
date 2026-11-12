import CmuxMobileShell
import SwiftUI

/// Observes prefetch inputs without adding dependencies to the workspace shell.
struct TaskComposerPrefetchObserver: View {
    let store: CMUXMobileShellStore
    @Environment(\.scenePhase) private var scenePhase

    private var prefetchTargets: [MobileTaskModelPrefetchTarget] {
        scenePhase == .background ? [] : store.taskModelPrefetchTargets
    }

    var body: some View {
        Color.clear
            .onChange(of: prefetchTargets, initial: true) { _, targets in
                store.updateTaskModelPrefetchTargets(targets)
            }
            .onDisappear {
                store.updateTaskModelPrefetchTargets([])
            }
    }
}
