import Foundation

@MainActor
final class GlobalSearchPanelCaptureManager {
    private let browserCaptureDebounceMilliseconds = 250
    private let markdownCaptureDebounceMilliseconds = 250
    private let indexProvider: () async -> SearchIndex?
    private let cancelPanelPurge: (UUID) -> Void
    private let agentSessionSource: (GlobalSearchPanelContext) -> AgentSessionSearchSource?
    private let agentSessionTranscripts: any AgentSessionTranscriptStore

    private var browserCaptureTimers: [UUID: DispatchSourceTimer] = [:]
    private var browserCaptureTasks: [UUID: Task<Void, Never>] = [:]
    private var browserCaptureTaskIDs: [UUID: UUID] = [:]
    private var markdownCaptureTimers: [UUID: DispatchSourceTimer] = [:]
    private var markdownCaptureTasks: [UUID: Task<Void, Never>] = [:]
    private var markdownCaptureTaskIDs: [UUID: UUID] = [:]
    /// Last indexed scrollback fingerprint per terminal panel, to skip
    /// unchanged re-captures across palette opens. Internal so tests can
    /// stand in for a scrollback capture.
    var terminalCaptureFingerprints: [UUID: UInt64] = [:]
    /// What each agent-session panel last indexed, to skip unchanged upserts.
    private var agentSessionIndexStates: [UUID: AgentSessionIndexState] = [:]
    /// Terminal panels with a refresh in flight. `cancelCaptures` bumps the
    /// generation, and a refresh that sees it moved after an await writes no
    /// document or state back for a pane that closed under it.
    private var terminalRefreshEpochs: [UUID: TerminalRefreshEpoch] = [:]

    private struct TerminalRefreshEpoch {
        var generation = 0
        var inFlight = 0
    }

    private struct AgentSessionIndexState: Equatable {
        let sessionID: String
        let revision: Int
        let title: String
        let location: String
    }

    init(
        indexProvider: @escaping () async -> SearchIndex?,
        cancelPanelPurge: @escaping (UUID) -> Void,
        agentSessionSource: @escaping (GlobalSearchPanelContext) -> AgentSessionSearchSource? = { _ in nil },
        agentSessionTranscripts: any AgentSessionTranscriptStore = AgentSessionSearchTranscripts()
    ) {
        self.indexProvider = indexProvider
        self.cancelPanelPurge = cancelPanelPurge
        self.agentSessionSource = agentSessionSource
        self.agentSessionTranscripts = agentSessionTranscripts
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
        } else if context.panel.panelType == .terminal {
            await refreshTerminalContent(for: context, index: index)
        }
    }

    /// Indexes a terminal pane's open agent session, or else its scrollback.
    private func refreshTerminalContent(for context: GlobalSearchPanelContext, index: SearchIndex) async {
        let panelID = context.panelID
        let generation = beginTerminalRefresh(forPanelID: panelID)
        defer { endTerminalRefresh(forPanelID: panelID) }

        if let source = agentSessionSource(context),
           await indexAgentSession(source, context: context, index: index, generation: generation) {
            return
        }
        guard isCurrentTerminalRefresh(panelID, generation: generation) else { return }
        await purgeAgentSessionDocument(forPanelID: panelID, index: index)
        guard isCurrentTerminalRefresh(panelID, generation: generation),
              let terminalPanel = context.panel as? TerminalPanel else {
            return
        }
        await indexTerminalPanel(terminalPanel, context: context, index: index, generation: generation)
    }

    private func beginTerminalRefresh(forPanelID panelID: UUID) -> Int {
        var epoch = terminalRefreshEpochs[panelID] ?? TerminalRefreshEpoch()
        epoch.inFlight += 1
        terminalRefreshEpochs[panelID] = epoch
        return epoch.generation
    }

    private func endTerminalRefresh(forPanelID panelID: UUID) {
        guard var epoch = terminalRefreshEpochs[panelID] else { return }
        epoch.inFlight -= 1
        terminalRefreshEpochs[panelID] = epoch.inFlight > 0 ? epoch : nil
    }

    /// Whether a terminal refresh may still write: its task isn't cancelled
    /// and the panel's captures weren't cancelled since it began.
    private func isCurrentTerminalRefresh(_ panelID: UUID, generation: Int) -> Bool {
        !Task.isCancelled && terminalRefreshEpochs[panelID]?.generation == generation
    }

    /// Drops transcript readers for sessions no panel indexes anymore.
    func pruneAgentSessionReaders() async {
        let indexedSessionIDs = Set(agentSessionIndexStates.values.map(\.sessionID))
        await agentSessionTranscripts.retainOnly(sessionIDs: indexedSessionIDs)
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
        terminalCaptureFingerprints[panelID] = nil
        agentSessionIndexStates[panelID] = nil
        terminalRefreshEpochs[panelID]?.generation += 1
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

    /// Indexes a live terminal's scrollback.
    ///
    /// Reads through `boundedScreenTailVT`: Ghostty applies the row and byte
    /// bounds before anything crosses the FFI, and the read itself runs on the
    /// teardown coordinator, so a 50 MB scrollback (the configured default)
    /// never lands on the main actor — the failure mode issue #5757 fixed for
    /// `surface.read_text`. Sanitizing and hashing then run off-main too.
    private func indexTerminalPanel(
        _ panel: TerminalPanel,
        context: GlobalSearchPanelContext,
        index: SearchIndex,
        generation: Int
    ) async {
        let panelID = context.panelID
        let capturedVT = await panel.surface.boundedScreenTailVT(
            maxRows: GlobalSearchIndexingLimits.maxTerminalCaptureRows,
            maxBytes: GlobalSearchIndexingLimits.maxTerminalCaptureVTBytes
        )
        guard isCurrentTerminalRefresh(panelID, generation: generation) else { return }
        guard let capturedVT else {
            // No snapshot available (hibernated or torn down): keep whatever is
            // indexed, since the hit still routes to the panel. close() purges.
            return
        }

        let prepared = await Task.detached(priority: .utility) {
            let text = GlobalSearchTerminalText.strippedVT(capturedVT)
            return (text: text, fingerprint: GlobalSearchTerminalText.fingerprint(text))
        }.value
        guard isCurrentTerminalRefresh(panelID, generation: generation) else { return }
        guard terminalCaptureFingerprints[panelID] != prepared.fingerprint else { return }

        guard let document = GlobalSearchDocuments.terminalDocument(for: context, text: prepared.text) else {
            terminalCaptureFingerprints[panelID] = nil
            await purgeTerminalDocument(forPanelID: panelID, index: index)
            return
        }

        do {
            try await index.upsert(document)
            guard isCurrentTerminalRefresh(panelID, generation: generation) else { return }
            terminalCaptureFingerprints[panelID] = prepared.fingerprint
        } catch {
#if DEBUG
            cmuxDebugLog("globalSearch.terminal.upsert failed panel=\(panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
        }
    }

    /// Indexes an open agent session's transcript in place of the pane's
    /// scrollback: the transcript holds the whole conversation as clean text,
    /// while the scrollback holds a rendered, possibly cleared, copy of it.
    ///
    /// The transcript is read and the document built off the main actor.
    ///
    /// - Returns: Whether the transcript represents the pane. False while it
    ///   has no text yet or the upsert failed, so the scrollback is indexed;
    ///   true once the pane's captures were cancelled, so nothing more is.
    private func indexAgentSession(
        _ source: AgentSessionSearchSource,
        context: GlobalSearchPanelContext,
        index: SearchIndex,
        generation: Int
    ) async -> Bool {
        let panelID = context.panelID
        let previous = agentSessionIndexStates[panelID]
        let revision = await agentSessionTranscripts.refreshedRevision(for: source)
        guard isCurrentTerminalRefresh(panelID, generation: generation) else { return true }
        guard let revision else { return false }
        let title = GlobalSearchDocuments.agentSessionRowTitle(
            workspaceTitle: context.workspaceTitle,
            paneTitle: context.panelTitle,
            agentName: source.agentKind.displayName
        )
        let next = AgentSessionIndexState(
            sessionID: source.sessionID,
            revision: revision,
            title: title,
            location: context.location
        )
        guard next != previous else {
            // An overlapping refresh that fell back to the scrollback can
            // index it after this session's document landed.
            if terminalCaptureFingerprints.removeValue(forKey: panelID) != nil {
                await purgeTerminalDocument(forPanelID: panelID, index: index)
            }
            return true
        }
        guard let transcriptText = await agentSessionTranscripts.text(forSessionID: source.sessionID) else {
            return false
        }
        guard isCurrentTerminalRefresh(panelID, generation: generation) else { return true }
        let windowID = context.windowID
        let workspaceID = context.workspaceID
        let location = context.location
        let document = await Task.detached(priority: .utility) {
            GlobalSearchDocuments.agentSessionDocument(
                windowID: windowID,
                workspaceID: workspaceID,
                panelID: panelID,
                location: location,
                source: source,
                title: title,
                transcriptText: transcriptText
            )
        }.value
        guard isCurrentTerminalRefresh(panelID, generation: generation) else { return true }
        do {
            try await index.upsert(document)
            guard isCurrentTerminalRefresh(panelID, generation: generation) else { return true }
            agentSessionIndexStates[panelID] = next
        } catch {
#if DEBUG
            cmuxDebugLog("globalSearch.agentSession.upsert failed panel=\(panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
            return false
        }
        if terminalCaptureFingerprints.removeValue(forKey: panelID) != nil || previous == nil {
            await purgeTerminalDocument(forPanelID: panelID, index: index)
        }
        return true
    }

    private func purgeAgentSessionDocument(forPanelID panelID: UUID, index: SearchIndex) async {
        guard let state = agentSessionIndexStates[panelID] else { return }
        let documentID = SearchIndexDocument.panelStableID(panelID: panelID, kind: .agentSession)
        do {
            try await index.deleteDocument(id: documentID)
            // The index is the source of truth for whether the session document
            // is gone. Keep the state so a failed delete is retried next time;
            // do not clear a newer session state that arrived while awaiting.
            if agentSessionIndexStates[panelID] == state {
                agentSessionIndexStates[panelID] = nil
            }
        } catch {
#if DEBUG
            cmuxDebugLog("globalSearch.agentSession.purge failed panel=\(panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
        }
    }

    private func purgeTerminalDocument(forPanelID panelID: UUID, index: SearchIndex) async {
        let documentID = SearchIndexDocument.panelStableID(panelID: panelID, kind: .terminal)
        do {
            try await index.deleteDocument(id: documentID)
        } catch {
#if DEBUG
            cmuxDebugLog("globalSearch.terminal.purge failed panel=\(panelID.uuidString.prefix(5)) error=\(error.localizedDescription)")
#endif
        }
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
