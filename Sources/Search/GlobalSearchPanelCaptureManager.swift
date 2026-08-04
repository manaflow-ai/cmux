import Foundation

@MainActor
final class GlobalSearchPanelCaptureManager {
    private let browserCaptureDebounceMilliseconds = 250
    private let markdownCaptureDebounceMilliseconds = 250
    private let indexProvider: () async -> SearchIndex?
    private let cancelPanelPurge: (UUID) -> Void

    private var contentIndexGeneration: UInt64 = 0
    private var indexedBrowserPanelIDs = Set<UUID>()
    private var indexedMarkdownPanelIDs = Set<UUID>()
    private var panelContentRevisions: [UUID: UInt64] = [:]
    private var browserCaptureTimers: [UUID: DispatchSourceTimer] = [:]
    private var browserCaptureTasks: [UUID: Task<Void, Never>] = [:]
    private var browserCaptureTaskIDs: [UUID: UUID] = [:]
    private var markdownCaptureTimers: [UUID: DispatchSourceTimer] = [:]
    private var markdownCaptureTasks: [UUID: Task<Void, Never>] = [:]
    private var markdownCaptureTaskIDs: [UUID: UUID] = [:]

    init(
        indexProvider: @escaping () async -> SearchIndex?,
        cancelPanelPurge: @escaping (UUID) -> Void
    ) {
        self.indexProvider = indexProvider
        self.cancelPanelPurge = cancelPanelPurge
    }

    /// Reconciles content during each Search presentation.
    ///
    /// Markdown content/file callbacks own subsequent dirty captures. Browser
    /// panels are recaptured once per reconciliation because same-document DOM
    /// changes do not emit a reliable browser lifecycle callback; the per-panel
    /// debounce keeps rapid refreshes coalesced to one active capture.
    func refreshPanelContent(for context: GlobalSearchPanelContext) async {
        if let markdownPanel = context.panel as? MarkdownPanel {
            guard !indexedMarkdownPanelIDs.contains(context.panelID) else {
                return
            }
            await captureInitialMarkdownPanel(markdownPanel, context: context)
        } else if let browserPanel = context.panel as? BrowserPanel {
            captureBrowserPanel(browserPanel)
        }
    }

    func resetIndexedContent() {
        contentIndexGeneration &+= 1
        let trackedPanelIDs = indexedBrowserPanelIDs
            .union(indexedMarkdownPanelIDs)
            .union(browserCaptureTaskIDs.keys)
            .union(markdownCaptureTaskIDs.keys)
            .union(panelContentRevisions.keys)
        for panelID in trackedPanelIDs {
            cancelBrowserCapture(forPanelID: panelID)
            cancelMarkdownCapture(forPanelID: panelID)
        }
        indexedBrowserPanelIDs.removeAll()
        indexedMarkdownPanelIDs.removeAll()
        panelContentRevisions.removeAll()
    }

    func reconcileLivePanels(_ livePanelIDs: Set<UUID>) {
        let trackedPanelIDs = indexedBrowserPanelIDs
            .union(indexedMarkdownPanelIDs)
            .union(browserCaptureTaskIDs.keys)
            .union(markdownCaptureTaskIDs.keys)
            .union(panelContentRevisions.keys)
        for panelID in trackedPanelIDs where !livePanelIDs.contains(panelID) {
            cancelCaptures(forPanelID: panelID)
        }
    }

    func captureBrowserPanel(_ panel: BrowserPanel) {
        let panelID = panel.id
        let taskID = UUID()
        let generation = contentIndexGeneration
        let panelRevision = markPanelContentDirty(panelID)
        cancelPanelPurge(panelID)
        cancelBrowserCapture(forPanelID: panelID)
        indexedBrowserPanelIDs.remove(panelID)
        browserCaptureTaskIDs[panelID] = taskID

        let timer = makeDebounceTimer(milliseconds: browserCaptureDebounceMilliseconds) { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                guard let self,
                      self.browserCaptureTaskIDs[panelID] == taskID else {
                    return
                }
                self.browserCaptureTimers[panelID]?.cancel()
                self.browserCaptureTimers[panelID] = nil

                let task = Task { @MainActor [weak self, weak panel] in
                    guard let self else { return }
                    defer {
                        if self.browserCaptureTaskIDs[panelID] == taskID {
                            self.browserCaptureTasks[panelID] = nil
                            self.browserCaptureTaskIDs[panelID] = nil
                        }
                    }

                    guard !Task.isCancelled,
                          self.browserCaptureTaskIDs[panelID] == taskID,
                          self.contentIndexGeneration == generation,
                          self.panelContentRevisions[panelID] == panelRevision,
                          let panel else {
                        return
                    }

                    await self.indexBrowserPanel(
                        panel,
                        generation: generation,
                        panelRevision: panelRevision
                    )
                }
                self.browserCaptureTasks[panelID] = task
            }
        }
        browserCaptureTimers[panelID] = timer
        timer.resume()
    }

    func captureMarkdownPanel(_ panel: MarkdownPanel) {
        let panelID = panel.id
        let capture = beginMarkdownCapture(for: panel)
        guard !panel.isFileUnavailable else {
            let task = makeMarkdownCaptureTask(
                panel,
                context: nil,
                taskID: capture.taskID,
                generation: capture.generation,
                panelRevision: capture.panelRevision
            )
            markdownCaptureTasks[panelID] = task
            return
        }

        let timer = makeDebounceTimer(milliseconds: markdownCaptureDebounceMilliseconds) { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                guard let self,
                      self.markdownCaptureTaskIDs[panelID] == capture.taskID else {
                    return
                }
                self.markdownCaptureTimers[panelID]?.cancel()
                self.markdownCaptureTimers[panelID] = nil

                guard let panel else {
                    self.markdownCaptureTaskIDs[panelID] = nil
                    return
                }
                let task = self.makeMarkdownCaptureTask(
                    panel,
                    context: nil,
                    taskID: capture.taskID,
                    generation: capture.generation,
                    panelRevision: capture.panelRevision
                )
                self.markdownCaptureTasks[panelID] = task
            }
        }
        markdownCaptureTimers[panelID] = timer
        timer.resume()
    }

    private func captureInitialMarkdownPanel(
        _ panel: MarkdownPanel,
        context: GlobalSearchPanelContext
    ) async {
        let capture = beginMarkdownCapture(for: panel)
        let task = makeMarkdownCaptureTask(
            panel,
            context: context,
            taskID: capture.taskID,
            generation: capture.generation,
            panelRevision: capture.panelRevision
        )
        markdownCaptureTasks[panel.id] = task

        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func beginMarkdownCapture(
        for panel: MarkdownPanel
    ) -> (taskID: UUID, generation: UInt64, panelRevision: UInt64) {
        let panelID = panel.id
        let generation = contentIndexGeneration
        let panelRevision = markPanelContentDirty(panelID)
        if !panel.isFileUnavailable {
            cancelPanelPurge(panelID)
        }
        cancelMarkdownCapture(forPanelID: panelID)
        indexedMarkdownPanelIDs.remove(panelID)

        let taskID = UUID()
        markdownCaptureTaskIDs[panelID] = taskID
        return (taskID, generation, panelRevision)
    }

    private func makeMarkdownCaptureTask(
        _ panel: MarkdownPanel,
        context: GlobalSearchPanelContext?,
        taskID: UUID,
        generation: UInt64,
        panelRevision: UInt64
    ) -> Task<Void, Never> {
        let panelID = panel.id
        return Task { @MainActor [weak self, weak panel] in
            guard let self else { return }
            defer {
                if self.markdownCaptureTaskIDs[panelID] == taskID {
                    self.markdownCaptureTasks[panelID] = nil
                    self.markdownCaptureTaskIDs[panelID] = nil
                }
            }

            guard self.isCurrentMarkdownCapture(
                panelID: panelID,
                taskID: taskID,
                generation: generation,
                panelRevision: panelRevision
            ),
                  let panel,
                  let index = await self.indexProvider() else {
                return
            }

            if panel.isFileUnavailable {
                let didPurge = await self.purgeMarkdownDocument(
                    forPanelID: panelID,
                    index: index
                )
                guard didPurge,
                      self.isCurrentMarkdownCapture(
                          panelID: panelID,
                          taskID: taskID,
                          generation: generation,
                          panelRevision: panelRevision
                      ) else {
                    return
                }
                self.indexedMarkdownPanelIDs.insert(panelID)
                return
            }

            guard let resolvedContext = context ?? AppDelegate.shared?.globalSearchContext(
                forPanelID: panel.id,
                preferredWorkspaceID: panel.workspaceId
            ),
                  let document = GlobalSearchDocuments.markdownDocument(
                      for: panel,
                      context: resolvedContext
                  ) else {
                return
            }

            do {
                try await index.upsert(document)
                guard self.isCurrentMarkdownCapture(
                    panelID: panelID,
                    taskID: taskID,
                    generation: generation,
                    panelRevision: panelRevision
                ) else {
                    return
                }
                self.indexedMarkdownPanelIDs.insert(panelID)
            } catch {
                guard !Task.isCancelled else { return }
#if DEBUG
                cmuxDebugLog("globalSearch.markdown.capture failed panel=\(panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
            }
        }
    }

    private func isCurrentMarkdownCapture(
        panelID: UUID,
        taskID: UUID,
        generation: UInt64,
        panelRevision: UInt64
    ) -> Bool {
        !Task.isCancelled
            && markdownCaptureTaskIDs[panelID] == taskID
            && contentIndexGeneration == generation
            && panelContentRevisions[panelID] == panelRevision
    }

    func cancelCaptures(forPanelID panelID: UUID) {
        cancelBrowserCapture(forPanelID: panelID)
        cancelMarkdownCapture(forPanelID: panelID)
        indexedBrowserPanelIDs.remove(panelID)
        indexedMarkdownPanelIDs.remove(panelID)
        panelContentRevisions[panelID] = nil
    }

    private func cancelBrowserCapture(forPanelID panelID: UUID) {
        browserCaptureTimers[panelID]?.cancel()
        browserCaptureTimers[panelID] = nil
        browserCaptureTasks[panelID]?.cancel()
        browserCaptureTasks[panelID] = nil
        browserCaptureTaskIDs[panelID] = nil
    }

    private func cancelMarkdownCapture(forPanelID panelID: UUID) {
        markdownCaptureTimers[panelID]?.cancel()
        markdownCaptureTimers[panelID] = nil
        markdownCaptureTasks[panelID]?.cancel()
        markdownCaptureTasks[panelID] = nil
        markdownCaptureTaskIDs[panelID] = nil
    }

    private func makeDebounceTimer(
        milliseconds: Int,
        handler: @escaping () -> Void
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(milliseconds), leeway: .milliseconds(25))
        timer.setEventHandler(handler: handler)
        return timer
    }

    private func purgeMarkdownDocument(forPanelID panelID: UUID, index: SearchIndex) async -> Bool {
        let documentID = SearchIndexDocument.panelStableID(panelID: panelID, kind: .markdown)
        do {
            try await index.deleteDocument(id: documentID)
            return true
        } catch {
            guard !Task.isCancelled else { return false }
#if DEBUG
            cmuxDebugLog("globalSearch.markdown.purge failed panel=\(panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    private func indexBrowserPanel(
        _ panel: BrowserPanel,
        generation: UInt64,
        panelRevision: UInt64
    ) async {
        guard let context = AppDelegate.shared?.globalSearchContext(
            forPanelID: panel.id,
            preferredWorkspaceID: panel.workspaceId
        ),
            let index = await indexProvider() else {
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
            guard !Task.isCancelled,
                  contentIndexGeneration == generation,
                  panelContentRevisions[panel.id] == panelRevision else {
                return
            }
            indexedBrowserPanelIDs.insert(panel.id)
        } catch {
            guard !Task.isCancelled else { return }
#if DEBUG
            cmuxDebugLog("globalSearch.browser.upsert failed panel=\(panel.id.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
        }
    }

    private func markPanelContentDirty(_ panelID: UUID) -> UInt64 {
        let revision = (panelContentRevisions[panelID] ?? 0) &+ 1
        panelContentRevisions[panelID] = revision
        return revision
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
