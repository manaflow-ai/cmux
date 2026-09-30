import CmuxMobileShell
import SwiftUI

/// Keeps connection observations out of the root view's rendering dependencies.
struct TaskComposerPrefetchModifier: ViewModifier {
    let store: CMUXMobileShellStore

    func body(content: Content) -> some View {
        content
            // Keep the observation in a leaf view. Reading the target list
            // from this modifier body would make every connection update a
            // dependency of the entire workspace shell.
            .background(TaskComposerPrefetchObserver(store: store))
    }
}

private struct TaskComposerPrefetchObserver: View {
    let store: CMUXMobileShellStore
    @Environment(\.scenePhase) private var scenePhase

    private var prefetchTargets: [MobileTaskModelPrefetchTarget] {
        scenePhase == .active ? store.taskModelPrefetchTargets : []
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
