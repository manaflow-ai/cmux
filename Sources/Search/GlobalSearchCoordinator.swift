import AppKit
import Foundation

@MainActor
final class GlobalSearchCoordinator {
    static let shared = GlobalSearchCoordinator()

    private let browserCaptureDebounceMilliseconds = 250
    private let markdownCaptureDebounceMilliseconds = 250
    private var browserCaptureTasks: [UUID: Task<Void, Never>] = [:]
    private var browserCaptureTaskIDs: [UUID: UUID] = [:]
    private var markdownCaptureTasks: [UUID: Task<Void, Never>] = [:]
    private var markdownCaptureTaskIDs: [UUID: UUID] = [:]
    private var panelPurgeTasks: [UUID: Task<Void, Never>] = [:]
    private var panelPurgeTaskIDs: [UUID: UUID] = [:]
    private var startupIndexTask: Task<Void, Never>?
    private var indexState: SearchIndexState = .idle
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

    func activate(_ hit: SearchIndexHit, query: String) {
        popover.dismiss()
        AppDelegate.shared?.openGlobalSearchHit(hit, query: query)
    }

    func refreshLiveIndex() async {
        guard let index = await ensureIndex(), let appDelegate = AppDelegate.shared else { return }

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

            if let markdownPanel = context.panel as? MarkdownPanel {
                if markdownPanel.isFileUnavailable {
                    cancelMarkdownCapture(forPanelID: context.panelID)
                    await purgeMarkdownDocument(forPanelID: context.panelID, index: index)
                } else if let document = GlobalSearchDocuments.markdownDocument(for: markdownPanel, context: context) {
                    do {
                        try await index.upsert(document)
                    } catch {
#if DEBUG
                        cmuxDebugLog("globalSearch.markdown.upsert failed panel=\(context.panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
                    }
                }
            } else if let browserPanel = context.panel as? BrowserPanel {
                captureBrowserPanel(browserPanel)
            }
        }
    }

    func captureBrowserPanel(_ panel: BrowserPanel) {
        let panelID = panel.id
        let taskID = UUID()
        cancelPanelPurge(forPanelID: panelID)
        browserCaptureTasks[panelID]?.cancel()
        browserCaptureTaskIDs[panelID] = taskID

        let task = Task { @MainActor [weak self, weak panel] in
            guard let self else { return }
            defer {
                if self.browserCaptureTaskIDs[panelID] == taskID {
                    self.browserCaptureTasks[panelID] = nil
                    self.browserCaptureTaskIDs[panelID] = nil
                }
            }

            do {
                try await Task.sleep(for: .milliseconds(browserCaptureDebounceMilliseconds))
            } catch {
                return
            }

            guard !Task.isCancelled,
                  self.browserCaptureTaskIDs[panelID] == taskID,
                  let panel else {
                return
            }

            await self.indexBrowserPanel(panel)
        }
        browserCaptureTasks[panelID] = task
    }

    func captureMarkdownPanel(_ panel: MarkdownPanel) {
        let panelID = panel.id
        guard !panel.isFileUnavailable else {
            cancelMarkdownCapture(forPanelID: panelID)
            let taskID = UUID()
            markdownCaptureTaskIDs[panelID] = taskID
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.markdownCaptureTaskIDs[panelID] == taskID {
                        self.markdownCaptureTasks[panelID] = nil
                        self.markdownCaptureTaskIDs[panelID] = nil
                    }
                }

                guard !Task.isCancelled,
                      self.markdownCaptureTaskIDs[panelID] == taskID,
                      let index = await self.ensureIndex() else {
                    return
                }

                await self.purgeMarkdownDocument(forPanelID: panelID, index: index)
            }
            markdownCaptureTasks[panelID] = task
            return
        }

        cancelPanelPurge(forPanelID: panelID)
        guard let context = AppDelegate.shared?.globalSearchContext(
            forPanelID: panel.id,
            preferredWorkspaceID: panel.workspaceId
        ),
            let document = GlobalSearchDocuments.markdownDocument(for: panel, context: context) else {
            return
        }

        let taskID = UUID()
        markdownCaptureTasks[panelID]?.cancel()
        markdownCaptureTaskIDs[panelID] = taskID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.markdownCaptureTaskIDs[panelID] == taskID {
                    self.markdownCaptureTasks[panelID] = nil
                    self.markdownCaptureTaskIDs[panelID] = nil
                }
            }

            do {
                try await Task.sleep(for: .milliseconds(markdownCaptureDebounceMilliseconds))
            } catch {
                return
            }

            guard !Task.isCancelled,
                  self.markdownCaptureTaskIDs[panelID] == taskID,
                  let index = await self.ensureIndex() else {
                return
            }

            do {
                try await index.upsert(document)
            } catch {
                guard !Task.isCancelled else { return }
#if DEBUG
                cmuxDebugLog("globalSearch.markdown.capture failed panel=\(panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
            }
        }
        markdownCaptureTasks[panelID] = task
    }

    func purgePanel(id panelID: UUID) {
        browserCaptureTasks[panelID]?.cancel()
        browserCaptureTasks[panelID] = nil
        browserCaptureTaskIDs[panelID] = nil
        cancelMarkdownCapture(forPanelID: panelID)
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

    private func cancelMarkdownCapture(forPanelID panelID: UUID) {
        markdownCaptureTasks[panelID]?.cancel()
        markdownCaptureTasks[panelID] = nil
        markdownCaptureTaskIDs[panelID] = nil
    }

    private func purgeMarkdownDocument(forPanelID panelID: UUID, index: SearchIndex) async {
        let documentID = SearchIndexDocument.panelStableID(panelID: panelID, kind: .markdown)
        do {
            try await index.deleteDocument(id: documentID)
        } catch {
#if DEBUG
            cmuxDebugLog("globalSearch.markdown.purge failed panel=\(panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
        }
    }

    private func ensureIndex() async -> SearchIndex? {
        switch indexState {
        case .ready(let index):
            return index
        case .failed:
            return nil
        case .opening(let task):
            return await resolveIndexOpeningTask(task)
        case .idle:
            let task = Task { try await SearchIndex.open() }
            indexState = .opening(task)
            return await resolveIndexOpeningTask(task)
        }
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

    private func indexBrowserPanel(_ panel: BrowserPanel) async {
        guard let context = AppDelegate.shared?.globalSearchContext(
            forPanelID: panel.id,
            preferredWorkspaceID: panel.workspaceId
        ),
            let index = await ensureIndex() else {
            return
        }

        guard !Task.isCancelled else { return }
        let payload = await browserPagePayload(for: panel)
        guard !Task.isCancelled else { return }
        let fallbackTitle = panel.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = GlobalSearchDocuments.firstNonEmpty(payload?.title, panel.pageTitle, fallbackTitle)
            ?? String(localized: "globalSearch.untitled", defaultValue: "Untitled")
        let location = GlobalSearchDocuments.firstNonEmpty(payload?.url, panel.currentURL?.absoluteString) ?? ""
        let bodyText = GlobalSearchDocuments.firstNonEmpty(payload?.text) ?? ""
        let text = GlobalSearchDocuments.cappedText([title, location, bodyText].filter { !$0.isEmpty }.joined(separator: "\n"))
        guard !text.isEmpty else { return }

        let anchor = GlobalSearchDocuments.firstNonEmpty(location, panel.id.uuidString) ?? panel.id.uuidString
        let document = SearchIndexDocument(
            id: SearchIndexDocument.panelStableID(panelID: context.panelID, kind: .browser),
            windowID: context.windowID,
            workspaceID: context.workspaceID,
            panelID: context.panelID,
            kind: .browser,
            title: title,
            location: location.isEmpty ? context.location : location,
            anchor: anchor,
            text: text
        )

        do {
            guard !Task.isCancelled else { return }
            try await index.upsert(document)
        } catch {
            guard !Task.isCancelled else { return }
#if DEBUG
            cmuxDebugLog("globalSearch.browser.upsert failed panel=\(panel.id.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
        }
    }

    private func browserPagePayload(for panel: BrowserPanel) async -> BrowserPagePayload? {
        let script = """
        (() => {
            const limit = \(GlobalSearchIndexingLimits.maxIndexedTextCharacters);
            const collectText = (root) => {
                if (!root) { return ""; }
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                const parts = [];
                let remaining = limit;
                let node;
                while (remaining > 0 && (node = walker.nextNode())) {
                    const value = node.nodeValue || "";
                    if (!value.trim()) { continue; }
                    const chunk = value.length > remaining ? value.slice(0, remaining) : value;
                    parts.push(chunk);
                    remaining -= chunk.length;
                }
                return parts.join(" ");
            };
            return JSON.stringify({
                title: document.title || "",
                url: location.href || "",
                text: collectText(document.body)
            });
        })()
        """
        do {
            guard let json = try await panel.evaluateJavaScript(script) as? String,
                  let data = json.data(using: .utf8) else {
                return nil
            }
            return try JSONDecoder().decode(BrowserPagePayload.self, from: data)
        } catch {
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
