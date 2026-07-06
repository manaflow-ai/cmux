import Combine
import Foundation

@MainActor
final class GlobalSearchWorkspaceMetadataIndexer {
    private let index: any SearchIndexWriting
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]

    init(index: any SearchIndexWriting) {
        self.index = index
    }

    func refresh(contexts: [GlobalSearchWorkspaceMetadataContext]) {
        let liveWorkspaceIDs = Set(contexts.map(\.workspaceID))
        for workspaceID in Array(subscriptions.keys) where !liveWorkspaceIDs.contains(workspaceID) {
            purgeWorkspace(id: workspaceID)
        }

        for context in contexts {
            upsert(context: context)
            attachSubscriptionIfNeeded(for: context)
        }
    }

    func purgeWorkspace(id workspaceID: UUID) {
        subscriptions[workspaceID]?.cancel()
        subscriptions[workspaceID] = nil
        refreshTasks[workspaceID]?.cancel()
        refreshTasks[workspaceID] = nil

        Task {
            do {
                try await index.deleteWorkspace(workspaceID)
            } catch {
#if DEBUG
                cmuxDebugLog("globalSearch.workspace.purge failed workspace=\(workspaceID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
            }
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
        refreshTasks[context.workspaceID]?.cancel()
        let workspaceID = context.workspaceID
        let document = GlobalSearchDocuments.workspaceMetadataDocument(for: context)
        refreshTasks[context.workspaceID] = Task { [index] in
            do {
                try await index.upsert(document)
            } catch {
#if DEBUG
                cmuxDebugLog("globalSearch.workspace.upsert failed workspace=\(workspaceID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
            }
        }
    }
}
