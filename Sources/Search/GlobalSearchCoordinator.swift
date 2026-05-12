import AppKit
import Foundation

@MainActor
struct GlobalSearchPanelContext {
    let windowID: UUID
    let windowTitle: String
    let workspaceID: UUID
    let workspaceTitle: String
    let panelID: UUID
    let panelTitle: String
    let panel: any Panel

    var location: String {
        "\(windowTitle) > \(workspaceTitle)"
    }
}

@MainActor
final class GlobalSearchCoordinator {
    static let shared = GlobalSearchCoordinator()

    private let maxIndexedTextCharacters = 400_000
    private let browserCaptureDebounceMilliseconds = 250
    private let markdownCaptureDebounceMilliseconds = 250
    private var browserCaptureTasks: [UUID: Task<Void, Never>] = [:]
    private var browserCaptureTaskIDs: [UUID: UUID] = [:]
    private var markdownCaptureTasks: [UUID: Task<Void, Never>] = [:]
    private var markdownCaptureTaskIDs: [UUID: UUID] = [:]
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

            let titleDocument = titleDocument(for: context)
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
                } else if let document = markdownDocument(for: markdownPanel, context: context) {
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
            Task { @MainActor [weak self] in
                guard let self, let index = await self.ensureIndex() else { return }
                await self.purgeMarkdownDocument(forPanelID: panelID, index: index)
            }
            return
        }

        guard let context = AppDelegate.shared?.globalSearchContext(
            forPanelID: panel.id,
            preferredWorkspaceID: panel.workspaceId
        ),
            let document = markdownDocument(for: panel, context: context) else {
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
        Task { @MainActor [weak self] in
            guard let self, let index = await self.ensureIndex() else { return }
            do {
                try await index.deletePanel(panelID)
            } catch {
#if DEBUG
                cmuxDebugLog("globalSearch.panel.purge failed panel=\(panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
            }
        }
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
        let title = firstNonEmpty(payload?.title, panel.pageTitle, fallbackTitle)
            ?? String(localized: "globalSearch.untitled", defaultValue: "Untitled")
        let location = firstNonEmpty(payload?.url, panel.currentURL?.absoluteString) ?? ""
        let bodyText = firstNonEmpty(payload?.text) ?? ""
        let text = cappedText([title, location, bodyText].filter { !$0.isEmpty }.joined(separator: "\n"))
        guard !text.isEmpty else { return }

        let anchor = firstNonEmpty(location, panel.id.uuidString) ?? panel.id.uuidString
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
            const limit = \(maxIndexedTextCharacters);
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

    private func titleDocument(for context: GlobalSearchPanelContext) -> SearchIndexDocument {
        let text = [
            context.windowTitle,
            context.workspaceTitle,
            context.panelTitle
        ].filter { !$0.isEmpty }.joined(separator: "\n")

        return SearchIndexDocument(
            id: SearchIndexDocument.panelStableID(panelID: context.panelID, kind: .title),
            windowID: context.windowID,
            workspaceID: context.workspaceID,
            panelID: context.panelID,
            kind: .title,
            title: context.panelTitle,
            location: context.location,
            anchor: "title",
            text: text
        )
    }

    private func markdownDocument(for panel: MarkdownPanel, context: GlobalSearchPanelContext) -> SearchIndexDocument? {
        let title = panel.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = cappedText([title, panel.filePath, panel.content].filter { !$0.isEmpty }.joined(separator: "\n"))
        guard !text.isEmpty else { return nil }

        return SearchIndexDocument(
            id: SearchIndexDocument.panelStableID(panelID: context.panelID, kind: .markdown),
            windowID: context.windowID,
            workspaceID: context.workspaceID,
            panelID: context.panelID,
            kind: .markdown,
            title: title,
            location: panel.filePath,
            anchor: panel.filePath,
            text: text
        )
    }

    private func cappedText(_ text: String) -> String {
        guard text.count > maxIndexedTextCharacters else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: maxIndexedTextCharacters)
        return String(text[..<endIndex])
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

private enum SearchIndexState {
    case idle
    case opening(Task<SearchIndex, Error>)
    case ready(SearchIndex)
    case failed
}

private struct BrowserPagePayload: Decodable {
    let title: String
    let url: String
    let text: String
}

extension AppDelegate {
    func globalSearchPanelContexts() -> [GlobalSearchPanelContext] {
        var contexts: [GlobalSearchPanelContext] = []
        var seenPanelKeys = Set<String>()
        var windowOrdinal = 1

        func append(windowID: UUID, tabManager: TabManager, window: NSWindow?) {
            let fallbackWindowTitle = String(localized: "menu.windowNumber", defaultValue: "Window \(windowOrdinal)")
            windowOrdinal += 1
            let windowTitle = {
                let trimmed = window?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? fallbackWindowTitle : trimmed
            }()

            for workspace in tabManager.tabs {
                let workspaceTitle = {
                    let trimmed = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty
                        ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
                        : trimmed
                }()

                for panel in workspace.panels.values {
                    let key = "\(windowID.uuidString):\(workspace.id.uuidString):\(panel.id.uuidString)"
                    guard seenPanelKeys.insert(key).inserted else { continue }
                    let panelTitle = panel.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    contexts.append(
                        GlobalSearchPanelContext(
                            windowID: windowID,
                            windowTitle: windowTitle,
                            workspaceID: workspace.id,
                            workspaceTitle: workspaceTitle,
                            panelID: panel.id,
                            panelTitle: panelTitle.isEmpty ? workspaceTitle : panelTitle,
                            panel: panel
                        )
                    )
                }
            }
        }

        for context in mainWindowContexts.values {
            append(
                windowID: context.windowId,
                tabManager: context.tabManager,
                window: context.window ?? windowForMainWindowId(context.windowId)
            )
        }

        for route in recoverableMainWindowRoutes() {
            guard let tabManager = route.tabManager else { continue }
            let alreadySeen = contexts.contains { $0.windowID == route.windowId }
            guard !alreadySeen else { continue }
            append(windowID: route.windowId, tabManager: tabManager, window: route.window)
        }

        return contexts
    }

    func globalSearchContext(
        forPanelID panelID: UUID,
        preferredWorkspaceID: UUID?
    ) -> GlobalSearchPanelContext? {
        var fallback: GlobalSearchPanelContext?
        var seenWindowIDs = Set<UUID>()
        var windowOrdinal = 1

        func inspect(windowID: UUID, tabManager: TabManager, window: NSWindow?) -> GlobalSearchPanelContext? {
            _ = seenWindowIDs.insert(windowID)
            let fallbackWindowTitle = String(localized: "menu.windowNumber", defaultValue: "Window \(windowOrdinal)")
            windowOrdinal += 1
            let windowTitle = {
                let trimmed = window?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? fallbackWindowTitle : trimmed
            }()

            for workspace in tabManager.tabs {
                guard let panel = workspace.panels[panelID] else { continue }
                let workspaceTitle = {
                    let trimmed = workspace.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty
                        ? String(localized: "workspace.displayName.fallback", defaultValue: "Workspace")
                        : trimmed
                }()
                let panelTitle = panel.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let context = GlobalSearchPanelContext(
                    windowID: windowID,
                    windowTitle: windowTitle,
                    workspaceID: workspace.id,
                    workspaceTitle: workspaceTitle,
                    panelID: panel.id,
                    panelTitle: panelTitle.isEmpty ? workspaceTitle : panelTitle,
                    panel: panel
                )

                if preferredWorkspaceID == nil || workspace.id == preferredWorkspaceID {
                    return context
                }
                fallback = fallback ?? context
            }

            return nil
        }

        for context in mainWindowContexts.values {
            if let result = inspect(
                windowID: context.windowId,
                tabManager: context.tabManager,
                window: context.window ?? windowForMainWindowId(context.windowId)
            ) {
                return result
            }
        }

        for route in recoverableMainWindowRoutes() {
            guard !seenWindowIDs.contains(route.windowId),
                  let tabManager = route.tabManager else {
                continue
            }
            if let result = inspect(windowID: route.windowId, tabManager: tabManager, window: route.window) {
                return result
            }
        }

        return fallback
    }

    func openGlobalSearchHit(_ hit: SearchIndexHit, query: String) {
        let resolvedContext = hit.panelID.flatMap {
            globalSearchContext(forPanelID: $0, preferredWorkspaceID: hit.workspaceID)
        }
        let windowID = resolvedContext?.windowID ?? hit.windowID
        let workspaceID = resolvedContext?.workspaceID ?? hit.workspaceID

        guard let tabManager = tabManagerFor(windowId: windowID),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }) else {
            NSSound.beep()
            return
        }

        _ = focusMainWindow(windowId: windowID)
        tabManager.selectTab(workspace)
        TerminalController.shared.setActiveTabManager(tabManager)

        if let panelID = hit.panelID, workspace.panels[panelID] != nil {
            tabManager.focusSurface(tabId: workspace.id, surfaceId: panelID)
            if let browserPanel = workspace.browserPanel(for: panelID) {
                applyBrowserInlineSearch(query: query, hit: hit, to: browserPanel)
            }
        }
    }

    private func applyBrowserInlineSearch(query: String, hit: SearchIndexHit, to panel: BrowserPanel) {
        guard let needle = GlobalSearchInlineSearch.browserNeedle(for: query, hit: hit) else { return }
        if let searchState = panel.searchState {
            searchState.needle = needle
        } else {
            panel.searchState = BrowserSearchState(needle: needle)
        }
    }
}

enum GlobalSearchInlineSearch {
    static func browserNeedle(for query: String, hit: SearchIndexHit) -> String? {
        let tokens = SearchIndex.queryTokens(for: query)
        guard !tokens.isEmpty else { return nil }

        let hitText = [
            hit.snippet,
            hit.title,
            hit.location,
            hit.anchor
        ].joined(separator: "\n").lowercased()

        return tokens.first { hitText.contains($0) } ?? tokens[0]
    }
}
