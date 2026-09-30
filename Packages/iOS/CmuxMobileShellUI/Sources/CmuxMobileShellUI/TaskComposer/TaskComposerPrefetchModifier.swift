import CmuxMobileShell
import SwiftUI

/// Keeps connection observations out of the root view's rendering dependencies.
struct TaskComposerPrefetchModifier: ViewModifier {
    let store: CMUXMobileShellStore
    @Environment(\.scenePhase) private var scenePhase

    private var prefetchTargets: [MobileTaskModelPrefetchTarget] {
        scenePhase == .active ? store.taskModelPrefetchTargets : []
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: prefetchTargets, initial: true) { _, targets in
                store.updateTaskModelPrefetchTargets(targets)
            }
            .onDisappear {
                store.updateTaskModelPrefetchTargets([])
            }
    }
}
