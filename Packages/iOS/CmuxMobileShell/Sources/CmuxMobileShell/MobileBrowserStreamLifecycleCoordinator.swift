import Foundation

/// Serializes browser stream lifecycle RPCs independently for each panel.
@MainActor
final class MobileBrowserStreamLifecycleCoordinator {
    private var tails: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    func run(
        panelID: String,
        operation: @escaping @MainActor () async -> Void
    ) async {
        let previous = tails[panelID]?.task
        let id = UUID()
        let task = Task { @MainActor in
            if let previous { await previous.value }
            await operation()
        }
        tails[panelID] = (id, task)
        await task.value
        if tails[panelID]?.id == id {
            tails[panelID] = nil
        }
    }
}
