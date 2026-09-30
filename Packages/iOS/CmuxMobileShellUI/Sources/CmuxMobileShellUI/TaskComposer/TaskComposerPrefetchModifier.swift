import CmuxMobileShell
import SwiftUI

/// Keeps connection observations out of the root view's rendering dependencies.
struct TaskComposerPrefetchModifier: ViewModifier {
    let store: CMUXMobileShellStore
    @Environment(\.scenePhase) private var scenePhase

    private var prefetchTargets: [MobileTaskModelPrefetchTarget] {
        store.taskModelPrefetchTargets
    }

    private var prefetchTaskID: String {
        let targetKey = prefetchTargets.map { target in
            [
                target.macDeviceID,
                target.instanceTag ?? "",
                target.connectionIdentity ?? "",
            ].joined(separator: "\u{1E}")
        }.joined(separator: "\u{1F}")
        [
            scenePhase == .active ? "active" : "inactive",
            targetKey,
        ].joined(separator: "\u{1F}")
    }

    func body(content: Content) -> some View {
        content.task(id: prefetchTaskID) {
            guard scenePhase == .active else { return }
            // Build the paired-Mac target snapshot once when the task starts.
            // Unrelated SwiftUI body passes never scan or sort the Mac list.
            await store.prefetchTaskModels(for: prefetchTargets)
        }
    }
}
