import CmuxMobileShell
import SwiftUI

/// Keeps connection observations out of the root view's rendering dependencies.
struct TaskComposerPrefetchModifier: ViewModifier {
    let store: CMUXMobileShellStore
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        let targets = scenePhase == .active ? store.taskModelPrefetchTargets : []
        content.task(id: targets) {
            await store.prefetchTaskModels(for: targets)
        }
    }
}
