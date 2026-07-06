import AppKit
import Foundation

@MainActor
final class GlobalSearchCoordinator {
    static let shared = GlobalSearchCoordinator()

    private var panelPurgeTasks: [UUID: Task<Void, Never>] = [:]
    private var panelPurgeTaskIDs: [UUID: UUID] = [:]
    private var startupIndexTask: Task<Void, Never>?
    private var indexState: SearchIndexState = .idle
    private var workspaceMetadataIndexer: GlobalSearchWorkspaceMetadataIndexer?
    private var transcriptIndexer: GlobalSearchTranscriptIndexer?
    private lazy var captureManager = GlobalSearchPanelCaptureManager(
        indexProvider: { [weak self] in
            guard let self else { return nil }
            return await self.ensureIndex()
        },
        cancelPanelPurge: { [weak self] panelID in
            self?.cancelPanelPurge(forPanelID: panelID)
        }
    )
    private lazy var popover = MenubarSearchPopover(coordinator: self)

    private init() {}

    func start() {
        startupIndexTask?.cancel()
        startupIndexTask = Task { @MainActor [weak self] in
            guard let self, let index = await self.ensureIndex() else { return }
            do {
                try await index.deleteAll()
            } catch {
#if DEBUG
                cmuxDebugLog("globalSearch.index.clear failed error=\(error.localizedDescription)")
#endif
            }

            guard !Task.isCancelled else { return }
            if let service = TerminalController.shared.agentChatTranscriptService {
                self.configureTranscriptIndexing(for: service)
            }
            await self.refreshLiveIndex()
            if !Task.isCancelled {
                self.startupIndexTask = nil
            }
        }
    }

    func togglePalette(anchor: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        popover.toggle(relativeTo: anchor, onDismiss: onDismiss)
    }

    func dismissPalette() {
        popover.dismiss()
    }

    func isPaletteVisible() -> Bool {
        popover.isShown
    }

    func search(query: String) async -> [SearchIndexHit] {
        guard let index = await ensureIndex() else { return [] }
        do {
            return try await index.search(query, limit: 20)
        } catch {
#if DEBUG
            cmuxDebugLog("globalSearch.search failed error=\(error.localizedDescription)")
#endif
            return []
        }
    }

    func browseOpenPanels(limit: Int = 20) -> [SearchIndexHit] {
        guard let appDelegate = AppDelegate.shared else { return [] }
        return appDelegate
            .globalSearchPanelContexts()
            .prefix(limit)
            .map { GlobalSearchDocuments.browseHit(for: $0) }
    }

    func activate(_ hit: SearchIndexHit, query: String) {
        popover.dismiss()
        AppDelegate.shared?.openGlobalSearchHit(hit, query: query)
    }

    func refreshLiveIndex() async {
        guard let index = await ensureIndex(), let appDelegate = AppDelegate.shared else { return }

        let metadataIndexer = workspaceIndexer(index: index)
        metadataIndexer.refresh(contexts: appDelegate.globalSearchWorkspaceMetadataContexts())

        for context in appDelegate.globalSearchPanelContexts() {
            guard !Task.isCancelled else { return }
            cancelPanelPurge(forPanelID: context.panelID)

            let titleDocument = GlobalSearchDocuments.titleDocument(for: context)
            do {
                try await index.upsert(titleDocument)
            } catch {
#if DEBUG
                cmuxDebugLog("globalSearch.title.upsert failed panel=\(context.panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
            }

            guard !Task.isCancelled else { return }

            await captureManager.refreshPanelContent(for: context, index: index)
        }
    }

    func captureBrowserPanel(_ panel: BrowserPanel) {
        captureManager.captureBrowserPanel(panel)
    }

    func captureMarkdownPanel(_ panel: MarkdownPanel) {
        captureManager.captureMarkdownPanel(panel)
    }

    func purgePanel(id panelID: UUID) {
        captureManager.cancelCaptures(forPanelID: panelID)
        panelPurgeTasks[panelID]?.cancel()

        let taskID = UUID()
        panelPurgeTaskIDs[panelID] = taskID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.panelPurgeTaskIDs[panelID] == taskID {
                    self.panelPurgeTasks[panelID] = nil
                    self.panelPurgeTaskIDs[panelID] = nil
                }
            }

            guard !Task.isCancelled,
                  self.panelPurgeTaskIDs[panelID] == taskID,
                  let index = await self.ensureIndex() else {
                return
            }

            do {
                guard !Task.isCancelled, self.panelPurgeTaskIDs[panelID] == taskID else { return }
                try await index.deletePanel(panelID)
            } catch {
                guard !Task.isCancelled else { return }
#if DEBUG
                cmuxDebugLog("globalSearch.panel.purge failed panel=\(panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
            }
        }
        panelPurgeTasks[panelID] = task
    }

    func purgeWorkspace(id workspaceID: UUID) {
        if let workspaceMetadataIndexer {
            workspaceMetadataIndexer.purgeWorkspace(id: workspaceID)
            return
        }
        Task { [weak self] in
            guard let self, let index = await self.ensureIndex() else { return }
            do {
                try await index.deleteWorkspace(workspaceID)
            } catch {
#if DEBUG
                cmuxDebugLog("globalSearch.workspace.purgeIndex failed workspace=\(workspaceID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
            }
        }
    }

    func configureTranscriptIndexing(for service: AgentChatTranscriptService) {
        Task { @MainActor [weak self, weak service] in
            guard let self, let service, let index = await self.ensureIndex() else { return }
            let indexer = self.transcriptIndexer ?? GlobalSearchTranscriptIndexer(
                index: index,
                routing: { workspaceID, surfaceID in
                    await MainActor.run {
                        AppDelegate.shared?.globalSearchTranscriptRouting(
                            workspaceID: workspaceID,
                            surfaceID: surfaceID
                        )
                    }
                }
            )
            self.transcriptIndexer = indexer
            service.enableSearchIndexing(indexer: indexer)
        }
    }

    private func cancelPanelPurge(forPanelID panelID: UUID) {
        panelPurgeTasks[panelID]?.cancel()
        panelPurgeTasks[panelID] = nil
        panelPurgeTaskIDs[panelID] = nil
    }

    private func workspaceIndexer(index: SearchIndex) -> GlobalSearchWorkspaceMetadataIndexer {
        if let workspaceMetadataIndexer {
            return workspaceMetadataIndexer
        }
        let created = GlobalSearchWorkspaceMetadataIndexer(index: index)
        workspaceMetadataIndexer = created
        return created
    }

    private func ensureIndex() async -> SearchIndex? {
        switch indexState {
        case .ready(let index):
            return index
        case .failed:
            return await openIndex()
        case .opening(let task):
            return await resolveIndexOpeningTask(task)
        case .idle:
            return await openIndex()
        }
    }

    private func openIndex() async -> SearchIndex? {
        let task = Task { try await SearchIndex.open() }
        indexState = .opening(task)
        return await resolveIndexOpeningTask(task)
    }

    private func resolveIndexOpeningTask(_ task: Task<SearchIndex, Error>) async -> SearchIndex? {
        do {
            let created = try await task.value
            if case .opening = indexState {
                indexState = .ready(created)
            }
            return created
        } catch {
            if case .opening = indexState {
                indexState = .failed
            }
#if DEBUG
            cmuxDebugLog("globalSearch.index.open failed error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

}

private enum SearchIndexState {
    case idle
    case opening(Task<SearchIndex, Error>)
    case ready(SearchIndex)
    case failed
}
