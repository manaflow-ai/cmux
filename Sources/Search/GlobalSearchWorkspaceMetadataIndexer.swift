import Combine
import Foundation

@MainActor
final class GlobalSearchWorkspaceMetadataIndexer {
    private let index: any SearchIndexWriting
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var indexTasks: [UUID: Task<Void, Never>] = [:]
    private var indexTaskIDs: [UUID: UUID] = [:]

    init(index: any SearchIndexWriting) {
        self.index = index
    }

    func refresh(contexts: [GlobalSearchWorkspaceMetadataContext]) {
        let liveWorkspaceIDs = Set(contexts.map(\.workspaceID))
        for workspaceID in Array(subscriptions.keys) where !liveWorkspaceIDs.contains(workspaceID) {
            cancelSubscription(id: workspaceID)
            deleteWorkspaceMetadataDocument(workspaceID: workspaceID)
        }

        for context in contexts {
            upsert(context: context)
            attachSubscriptionIfNeeded(for: context)
        }
    }

    func purgeWorkspace(id workspaceID: UUID) {
        cancelSubscription(id: workspaceID)
        scheduleIndexTask(for: workspaceID, action: "purge") { index in
            try await index.deleteWorkspace(workspaceID)
        }
    }

    private func attachSubscriptionIfNeeded(for context: GlobalSearchWorkspaceMetadataContext) {
        guard subscriptions[context.workspaceID] == nil else { return }
        let workspaceID = context.workspaceID
        subscriptions[workspaceID] = context.workspace
            .makeSidebarObservationPublisher()
            .merge(with: context.workspace.makeSidebarImmediateObservationPublisher())
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          let context = AppDelegate.shared?.globalSearchWorkspaceMetadataContext(forWorkspaceID: workspaceID) else {
                        return
                    }
                    self.upsert(context: context)
                }
            }
    }

    private func upsert(context: GlobalSearchWorkspaceMetadataContext) {
        let workspaceID = context.workspaceID
        let document = GlobalSearchDocuments.workspaceMetadataDocument(for: context)
        scheduleIndexTask(for: workspaceID, action: "upsert") { index in
            try await index.upsert(document)
        }
    }

    private func cancelSubscription(id workspaceID: UUID) {
        subscriptions[workspaceID]?.cancel()
        subscriptions[workspaceID] = nil
    }

    private func deleteWorkspaceMetadataDocument(workspaceID: UUID) {
        let documentID = GlobalSearchDocuments.workspaceMetadataDocumentID(workspaceID: workspaceID)
        scheduleIndexTask(for: workspaceID, action: "deleteMetadata") { index in
            try await index.deleteDocument(id: documentID)
        }
    }

    private func scheduleIndexTask(
        for workspaceID: UUID,
        action: String,
        operation: @escaping @Sendable (any SearchIndexWriting) async throws -> Void
    ) {
        let previousTask = indexTasks[workspaceID]
        let taskID = UUID()
        let index = index
        indexTaskIDs[workspaceID] = taskID
        let task = Task { [weak self] in
            _ = await previousTask?.result
            do {
                try await operation(index)
            } catch {
#if DEBUG
                cmuxDebugLog("globalSearch.workspace.\(action) failed workspace=\(workspaceID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
            }
            await MainActor.run {
                guard let self, self.indexTaskIDs[workspaceID] == taskID else { return }
                self.indexTasks[workspaceID] = nil
                self.indexTaskIDs[workspaceID] = nil
            }
        }
        indexTasks[workspaceID] = task
    }
}
