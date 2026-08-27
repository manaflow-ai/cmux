import Foundation

@MainActor
final class GlobalSearchPanelCaptureManager {
    private let browserCaptureDebounceMilliseconds = 250
    private let markdownCaptureDebounceMilliseconds = 250
    private let indexProvider: () async -> SearchIndex?
    private let cancelPanelPurge: (UUID) -> Void

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

    func refreshPanelContent(for context: GlobalSearchPanelContext, index: SearchIndex) async {
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

    func captureBrowserPanel(_ panel: BrowserPanel) {
        let panelID = panel.id
        let taskID = UUID()
        cancelPanelPurge(panelID)
        cancelBrowserCapture(forPanelID: panelID)
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
                          let panel else {
                        return
                    }

                    await self.indexBrowserPanel(panel)
                }
                self.browserCaptureTasks[panelID] = task
            }
        }
        browserCaptureTimers[panelID] = timer
        timer.resume()
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
                      let index = await self.indexProvider() else {
                    return
                }

                await self.purgeMarkdownDocument(forPanelID: panelID, index: index)
            }
            markdownCaptureTasks[panelID] = task
            return
        }

        cancelPanelPurge(panelID)
        let taskID = UUID()
        cancelMarkdownCapture(forPanelID: panelID)
        markdownCaptureTaskIDs[panelID] = taskID

        let timer = makeDebounceTimer(milliseconds: markdownCaptureDebounceMilliseconds) { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                guard let self,
                      self.markdownCaptureTaskIDs[panelID] == taskID else {
                    return
                }
                self.markdownCaptureTimers[panelID]?.cancel()
                self.markdownCaptureTimers[panelID] = nil

                let task = Task { @MainActor [weak self, weak panel] in
                    guard let self else { return }
                    defer {
                        if self.markdownCaptureTaskIDs[panelID] == taskID {
                            self.markdownCaptureTasks[panelID] = nil
                            self.markdownCaptureTaskIDs[panelID] = nil
                        }
                    }

                    guard !Task.isCancelled,
                          self.markdownCaptureTaskIDs[panelID] == taskID,
                          let panel,
                          let context = AppDelegate.shared?.globalSearchContext(
                              forPanelID: panel.id,
                              preferredWorkspaceID: panel.workspaceId
                          ),
                          let document = GlobalSearchDocuments.markdownDocument(for: panel, context: context),
                          let index = await self.indexProvider() else {
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
                self.markdownCaptureTasks[panelID] = task
            }
        }
        markdownCaptureTimers[panelID] = timer
        timer.resume()
    }

    func cancelCaptures(forPanelID panelID: UUID) {
        cancelBrowserCapture(forPanelID: panelID)
        cancelMarkdownCapture(forPanelID: panelID)
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

    private func indexBrowserPanel(_ panel: BrowserPanel) async {
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
