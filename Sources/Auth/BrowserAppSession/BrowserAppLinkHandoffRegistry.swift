import Foundation

@MainActor
final class BrowserAppLinkHandoffRegistry {
    private typealias Entry = (
        operationID: UUID,
        destinationURL: URL,
        task: Task<Void, Never>
    )

    private var entries: [UUID: Entry] = [:]

    var activeCount: Int { entries.count }

    @discardableResult
    func start(
        sourcePanelID: UUID,
        destinationURL: URL,
        operation: @escaping @MainActor () async -> Void
    ) -> Bool {
        if entries[sourcePanelID]?.destinationURL == destinationURL {
            return false
        }
        cancel(sourcePanelID: sourcePanelID)

        let operationID = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.finish(
                sourcePanelID: sourcePanelID,
                operationID: operationID
            )
        }
        entries[sourcePanelID] = (
            operationID: operationID,
            destinationURL: destinationURL,
            task: task
        )
        return true
    }

    func cancel(sourcePanelID: UUID) {
        entries.removeValue(forKey: sourcePanelID)?.task.cancel()
    }

    func cancelAll() {
        let tasks = entries.values.map(\.task)
        entries.removeAll()
        for task in tasks {
            task.cancel()
        }
    }

    private func finish(sourcePanelID: UUID, operationID: UUID) {
        guard entries[sourcePanelID]?.operationID == operationID else { return }
        entries.removeValue(forKey: sourcePanelID)
    }
}
