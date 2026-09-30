import CmuxMobileShell
import SwiftUI

/// Keeps connection observations out of the root view's rendering dependencies.
struct TaskComposerPrefetchModifier: ViewModifier {
    let store: CMUXMobileShellStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var targetChangePrefetchTask: Task<Void, Never>?

    private var prefetchTargets: [MobileTaskModelPrefetchTarget] {
        store.taskModelPrefetchTargets
    }

    private func pairingKey(for target: MobileTaskModelPrefetchTarget) -> String {
        [target.macDeviceID, target.instanceTag ?? ""].joined(separator: "\u{1E}")
    }

    func body(content: Content) -> some View {
        content.task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            // Build the paired-Mac target snapshot once when the task starts.
            // Unrelated SwiftUI body passes never scan or sort the Mac list.
            await store.prefetchTaskModels(for: prefetchTargets)
        }
        .onChange(of: prefetchTargets) { oldTargets, newTargets in
            guard scenePhase == .active else { return }
            let oldTargetsByPairing = Dictionary(
                uniqueKeysWithValues: oldTargets.map { (pairingKey(for: $0), $0) }
            )
            let changedTargets = newTargets.filter {
                oldTargetsByPairing[pairingKey(for: $0)] != $0
            }
            guard !changedTargets.isEmpty else { return }
            targetChangePrefetchTask?.cancel()
            targetChangePrefetchTask = Task { @MainActor in
                await store.prefetchTaskModels(for: changedTargets)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            targetChangePrefetchTask?.cancel()
            targetChangePrefetchTask = nil
        }
        .onDisappear {
            targetChangePrefetchTask?.cancel()
        }
    }
}
