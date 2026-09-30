import CmuxMobileShell
import SwiftUI

/// Keeps connection observations out of the root view's rendering dependencies.
struct TaskComposerPrefetchModifier: ViewModifier {
    let store: CMUXMobileShellStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshotPrefetchTask: Task<Void, Never>?
    @State private var targetChangePrefetchTask: Task<Void, Never>?

    private var prefetchTargets: [MobileTaskModelPrefetchTarget] {
        store.taskModelPrefetchTargets
    }

    private func pairingKey(for target: MobileTaskModelPrefetchTarget) -> String {
        [target.macDeviceID, target.instanceTag ?? ""].joined(separator: "\u{1E}")
    }

    private func startSnapshotPrefetch(for targets: [MobileTaskModelPrefetchTarget]) {
        guard scenePhase == .active else { return }
        snapshotPrefetchTask?.cancel()
        let store = store
        snapshotPrefetchTask = Task { @MainActor in
            await store.prefetchTaskModels(for: targets)
        }
    }

    private func cancelPrefetchTasks() {
        snapshotPrefetchTask?.cancel()
        snapshotPrefetchTask = nil
        targetChangePrefetchTask?.cancel()
        targetChangePrefetchTask = nil
    }

    func body(content: Content) -> some View {
        content
        .onAppear {
            // Build the paired-Mac target snapshot once when the host appears.
            // Unrelated SwiftUI body passes never scan or sort the Mac list.
            startSnapshotPrefetch(for: prefetchTargets)
        }
        .onChange(of: prefetchTargets) { oldTargets, newTargets in
            guard scenePhase == .active else { return }
            snapshotPrefetchTask?.cancel()
            snapshotPrefetchTask = nil
            targetChangePrefetchTask?.cancel()
            targetChangePrefetchTask = nil
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
            if phase == .active {
                startSnapshotPrefetch(for: prefetchTargets)
            } else {
                cancelPrefetchTasks()
            }
        }
        .onDisappear {
            cancelPrefetchTasks()
        }
    }
}
