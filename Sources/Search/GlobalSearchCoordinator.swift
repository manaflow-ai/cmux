import AppKit
import Foundation

@MainActor
final class GlobalSearchCoordinator {
    static let shared = GlobalSearchCoordinator()

    private var panelPurgeTasks: [UUID: Task<Void, Never>] = [:]
    private var panelPurgeTaskIDs: [UUID: UUID] = [:]
    private var startupIndexTask: Task<Void, Never>?
    private var indexState: SearchIndexState = .idle
    private var indexedTitleSnapshots: [UUID: GlobalSearchTitleSnapshot] = [:]
    private var titleIndexGeneration: UInt64 = 0
    private weak var activePresentation: GlobalSearchPopoverPresentation?
    private lazy var captureManager = GlobalSearchPanelCaptureManager(
        indexProvider: { [weak self] in
            guard let self else { return nil }
            return await self.ensureIndex()
        },
        cancelPanelPurge: { [weak self] panelID in
            self?.cancelPanelPurge(forPanelID: panelID)
        },
        contentDidChange: { [weak self] _ in
            self?.activePresentation?.searchIndexDidChange()
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
                guard !Task.isCancelled else { return }
#if DEBUG
                cmuxDebugLog("globalSearch.index.clear failed error=\(error.localizedDescription)")
#endif
            }

            guard !Task.isCancelled else { return }
            self.titleIndexGeneration &+= 1
            self.indexedTitleSnapshots.removeAll()
            self.captureManager.resetIndexedContent()
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

    func presentationDidBegin(_ presentation: GlobalSearchPopoverPresentation) {
        activePresentation = presentation
    }

    func presentationDidEnd(_ presentation: GlobalSearchPopoverPresentation) {
        guard activePresentation === presentation else { return }
        activePresentation = nil
    }

    func search(query: String) async -> [SearchIndexHit] {
        guard let index = await ensureIndex() else { return [] }
        do {
            return try await index.search(query, limit: 20)
        } catch is CancellationError {
            return []
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
        let contexts = appDelegate.globalSearchPanelContexts()
        captureManager.reconcileLivePanels(Set(contexts.map(\.panelID)))

        await refreshLivePanelTitles(contexts: contexts, index: index)
        guard !Task.isCancelled else { return }

        await captureManager.refreshPanelContent(for: contexts)
    }

    func refreshLivePanelTitles() async {
        guard let index = await ensureIndex(), let appDelegate = AppDelegate.shared else { return }
        await refreshLivePanelTitles(
            contexts: appDelegate.globalSearchPanelContexts(),
            index: index
        )
    }

    func captureBrowserPanel(_ panel: BrowserPanel) {
        captureManager.captureBrowserPanel(panel)
    }

    func captureMarkdownPanel(_ panel: MarkdownPanel) {
        captureManager.captureMarkdownPanel(panel)
    }

    func purgePanel(id panelID: UUID) {
        captureManager.cancelCaptures(forPanelID: panelID)
        indexedTitleSnapshots[panelID] = nil
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

    private func cancelPanelPurge(forPanelID panelID: UUID) {
        panelPurgeTasks[panelID]?.cancel()
        panelPurgeTasks[panelID] = nil
        panelPurgeTaskIDs[panelID] = nil
    }

    private func refreshLivePanelTitles(
        contexts: [GlobalSearchPanelContext],
        index: SearchIndex
    ) async {
        let refreshGeneration = titleIndexGeneration
        let livePanelIDs = Set(contexts.map(\.panelID))
        let stalePanelIDs = indexedTitleSnapshots.keys.filter { !livePanelIDs.contains($0) }
        for panelID in stalePanelIDs {
            indexedTitleSnapshots[panelID] = nil
        }

        for context in contexts {
            guard !Task.isCancelled,
                  titleIndexGeneration == refreshGeneration else {
                return
            }
            cancelPanelPurge(forPanelID: context.panelID)

            let snapshot = GlobalSearchTitleSnapshot(context: context)
            guard indexedTitleSnapshots[context.panelID] != snapshot else { continue }

            do {
                try await index.upsert(GlobalSearchDocuments.titleDocument(for: context))
                guard !Task.isCancelled,
                      titleIndexGeneration == refreshGeneration else {
                    return
                }
                indexedTitleSnapshots[context.panelID] = snapshot
            } catch {
                guard !Task.isCancelled else { return }
#if DEBUG
                cmuxDebugLog("globalSearch.title.upsert failed panel=\(context.panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
            }
        }
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
