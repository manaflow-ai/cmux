import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Observation

/// State for the ChatGPT/Codex-style agent mode. The model deliberately owns
/// only presentation state; transport remains behind ``ChatEventSource`` so
/// Claude Code, Codex, and OpenCode share the same event and action pipeline.
@MainActor
@Observable
final class AgentChatModeModel {
    /// Connection state for the source used by agent mode. A source can be
    /// present while its event stream is down, so this is deliberately kept
    /// separate from whether a session list was last loaded successfully.
    enum ConnectionState: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting
    }

    struct PendingAttachment: Identifiable, Sendable, Equatable {
        let id: UUID
        let displayName: String
        let data: Data
        let format: ChatOutboundAttachment.Format
        let thumbnailData: Data?

        init(
            id: UUID = UUID(),
            displayName: String,
            data: Data,
            format: ChatOutboundAttachment.Format,
            thumbnailData: Data? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.data = data
            self.format = format
            self.thumbnailData = thumbnailData
        }

        var outbound: ChatOutboundAttachment {
            ChatOutboundAttachment(data: data, format: format)
        }
    }

    private(set) var sessions: [ChatSessionDescriptor] = []
    private(set) var messagesBySession: [String: [ChatMessage]] = [:]
    private(set) var terminalBlocksBySession: [String: [TerminalCommandBlock]] = [:]
    private(set) var streamingBySession: [String: ChatMessage?] = [:]
    private(set) var loadingSessionIDs: Set<String> = []
    private(set) var sendingSessionIDs: Set<String> = []
    private(set) var interruptingSessionIDs: Set<String> = []
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var errorMessage: String?
    private(set) var attachments: [PendingAttachment] = []
    var selectedSessionID: String?
    var draft = ""
    var selectedProvider: String = "all"
    /// Case-insensitive search over the session title, provider, id, and
    /// working directory. Keeping this on the model makes the session list
    /// useful to non-SwiftUI consumers as well.
    var sessionSearchQuery = ""

    private var source: (any AgentChatSessionSource)?
    private var sourceTask: Task<Void, Never>?
    private var sessionTasks: [String: Task<Void, Never>] = [:]
    private var historyReloadTasks: [String: Task<Void, Never>] = [:]
    private var historyCursors: [String: Int] = [:]
    private var historyHasMore: [String: Bool] = [:]
    private var transcriptRevisions: [String: Int] = [:]
    private var historyResetTokens: [String: Int] = [:]
    private var pendingSendsBySession: [String: [QueuedSend]] = [:]
    /// Answer cards can remain visually pending until the host republishes the
    /// resolved transcript message. Keep a local guard so a double tap cannot
    /// submit the same decision twice during that window.
    private var answeringRequestKeys: Set<String> = []
    private var answeredRequestKeysBySession: [String: Set<String>] = [:]
    private var removedSessionVersions: [String: Int] = [:]
    private var sourceGeneration = 0
    private let reconnectDelay: @Sendable (_ attempt: Int) async -> Void

    init(
        reconnectDelay: @escaping @Sendable (_ attempt: Int) async -> Void = AgentChatModeModel.defaultReconnectDelay
    ) {
        self.reconnectDelay = reconnectDelay
    }

    /// Keep a dead transport from turning an EOF into a busy resubscribe loop.
    /// The delay is cancellable, so replacing the source or leaving the mode
    /// stops recovery immediately. Tests can inject an immediate delay.
    private nonisolated static func defaultReconnectDelay(attempt: Int) async {
        let milliseconds = min(5_000, 250 * (1 << min(max(attempt - 1, 0), 4)))
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private struct QueuedSend: Sendable {
        let text: String
        let attachments: [PendingAttachment]
    }

    var visibleSessions: [ChatSessionDescriptor] {
        let query = sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return sessions.filter { session in
            guard selectedProvider == "all" || session.agentKind.sourceName == selectedProvider else {
                return false
            }
            guard !query.isEmpty else { return true }
            let fields = [
                session.title,
                session.id,
                session.agentKind.displayName,
                session.workingDirectory,
                session.workspaceID,
            ].compactMap { $0 }
            return fields.contains {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    .contains(query)
            }
        }
    }

    var selectedSession: ChatSessionDescriptor? {
        guard let selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var selectedMessages: [ChatMessage] {
        guard let selectedSessionID else { return [] }
        return messagesBySession[selectedSessionID] ?? []
    }

    var selectedStreamingMessage: ChatMessage? {
        guard let selectedSessionID else { return nil }
        return streamingBySession[selectedSessionID] ?? nil
    }

    var selectedTerminalBlocks: [TerminalCommandBlock] {
        guard let selectedSessionID else { return [] }
        return terminalBlocksBySession[selectedSessionID] ?? []
    }

    var selectedHasMoreHistory: Bool {
        guard let selectedSessionID else { return false }
        return historyHasMore[selectedSessionID] == true
    }

    var queuedSendCount: Int {
        guard let selectedSessionID else { return 0 }
        return pendingSendsBySession[selectedSessionID]?.count ?? 0
    }

    func updateSource(_ next: (any AgentChatSessionSource)?) {
        sourceGeneration += 1
        let generation = sourceGeneration
        sourceTask?.cancel()
        for task in sessionTasks.values { task.cancel() }
        for task in historyReloadTasks.values { task.cancel() }
        sessionTasks = [:]
        historyReloadTasks = [:]
        source = next
        connectionState = next == nil ? .disconnected : .connecting
        sessions = []
        messagesBySession = [:]
        terminalBlocksBySession = [:]
        streamingBySession = [:]
        selectedSessionID = nil
        attachments = []
        historyCursors = [:]
        historyHasMore = [:]
        transcriptRevisions = [:]
        historyResetTokens = [:]
        pendingSendsBySession = [:]
        answeringRequestKeys = []
        answeredRequestKeysBySession = [:]
        removedSessionVersions = [:]
        loadingSessionIDs = []
        sendingSessionIDs = []
        interruptingSessionIDs = []
        guard let next else { return }
        sourceTask = Task { [weak self] in
            await self?.loadAndObserve(source: next, generation: generation)
        }
    }

    func refresh() async {
        guard let source else { return }
        let generation = sourceGeneration
        // Host streams finish when the transport closes. Re-open the stream
        // as part of an explicit refresh so a recovered connection resumes
        // receiving live session updates.
        if connectionState == .reconnecting {
            sourceTask?.cancel()
            connectionState = .connecting
            sourceTask = Task { [weak self] in
                await self?.observeHostEvents(source: source, generation: generation)
            }
        }
        await loadSessions(source: source, generation: generation)
        guard !Task.isCancelled, generation == sourceGeneration else { return }
        if let selectedSessionID {
            await loadHistory(
                sessionID: selectedSessionID,
                source: source,
                reset: true,
                generation: generation
            )
        }
    }

    func select(_ session: ChatSessionDescriptor) {
        selectedSessionID = session.id
        draft = ""
        attachments = []
        let staleSessionIDs = sessionTasks.keys.filter { $0 != session.id }
        for id in staleSessionIDs {
            sessionTasks[id]?.cancel()
            sessionTasks[id] = nil
        }
        guard let source else { return }
        let generation = sourceGeneration
        sessionTasks[session.id]?.cancel()
        sessionTasks[session.id] = Task { [weak self] in
            guard let self else { return }
            await self.loadHistory(
                sessionID: session.id,
                source: source,
                reset: true,
                generation: generation
            )
            guard !Task.isCancelled,
                  generation == self.sourceGeneration,
                  self.selectedSessionID == session.id else { return }
            await self.observe(sessionID: session.id, source: source, generation: generation)
        }
    }

    func loadOlderMessages() async {
        guard let selectedSessionID, historyHasMore[selectedSessionID] == true,
              let source else { return }
        await loadHistory(
            sessionID: selectedSessionID,
            source: source,
            reset: false,
            generation: sourceGeneration
        )
    }

    func sendDraft() async {
        guard let selectedSessionID,
              let source,
              selectedSession?.state != .ended,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAttachments = attachments
        draft = ""
        attachments = []
        pendingSendsBySession[selectedSessionID, default: []].append(
            QueuedSend(text: text, attachments: pendingAttachments)
        )
        await drainSendQueue(
            sessionID: selectedSessionID,
            source: source,
            generation: sourceGeneration
        )
    }

    /// Sends a follow-up into the current turn after a polite interrupt. The
    /// regular send action remains a safe queue operation while the agent is
    /// working; this explicit path gives mobile users the provider-style
    /// Steer choice without silently changing queue semantics.
    func steerDraft() async {
        guard let selectedSessionID,
              let source,
              selectedSession?.state != .ended,
              selectedSession?.isWorking == true,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAttachments = attachments
        draft = ""
        attachments = []
        do {
            try await source.steer(
                text: text,
                attachments: pendingAttachments.map(\.outbound),
                sessionID: selectedSessionID
            )
        } catch {
            guard !Task.isCancelled else { return }
            draft = text
            attachments = pendingAttachments
            errorMessage = error.localizedDescription
        }
    }

    func addAttachment(_ attachment: PendingAttachment) {
        guard attachments.count < 10 else {
            errorMessage = "You can attach up to 10 images."
            return
        }
        guard attachment.data.count <= MobileImageAttachmentPreparer.maximumEncodedBytes else {
            errorMessage = "That image is too large to send."
            return
        }
        let totalBytes = attachments.reduce(0) { $0 + $1.data.count }
        guard totalBytes + attachment.data.count <= 64 * 1024 * 1024 else {
            errorMessage = "Attachments can use up to 64 MB in total."
            return
        }
        guard !attachments.contains(where: { $0.data == attachment.data }) else { return }
        attachments.append(attachment)
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Stages image content from the system pasteboard. File and text
    /// representations remain available to their native paste paths.
    func stagePastedImages() async {
        let reader = MobilePasteboardReader()
        guard reader.hasAttachmentContent(in: .general) else {
            errorMessage = "No image is available to paste."
            return
        }
        let items = await reader.materializeAttachments(from: .general)
        defer { reader.cleanUp(items) }
        for item in items {
            guard !Task.isCancelled, item.kind == .image else { continue }
            guard attachments.count < 10 else {
                errorMessage = "You can attach up to 10 images."
                return
            }
            guard let prepared = await prepareImage(at: item.url) else {
                errorMessage = "That image couldn’t be prepared. Choose another image."
                continue
            }
            let format: ChatOutboundAttachment.Format =
                prepared.format.lowercased() == "jpg" || prepared.format.lowercased() == "jpeg"
                ? .jpeg : .png
            let stem = (item.displayName as NSString).deletingPathExtension
            addAttachment(PendingAttachment(
                displayName: (stem.isEmpty ? "pasted-image" : stem) + (format == .jpeg ? ".jpeg" : ".png"),
                data: prepared.data,
                format: format,
                thumbnailData: prepared.thumbnailData
            ))
        }
    }

    private func prepareImage(at url: URL) async -> MobilePreparedImageAttachment? {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey])
        } catch {
            return nil
        }
        guard let size = values.fileSize,
              size <= MobileImageAttachmentPreparer.maximumRawInputBytes else {
            return nil
        }
        return await MobileImageAttachmentPreparer().prepare(url: url)
    }

    func interrupt(hard: Bool = false) async {
        guard let selectedSessionID, let source, selectedSession?.state != .ended else { return }
        guard interruptingSessionIDs.insert(selectedSessionID).inserted else { return }
        defer { interruptingSessionIDs.remove(selectedSessionID) }
        do {
            try await source.interrupt(sessionID: selectedSessionID, hard: hard)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func answer(optionIndex: Int, requestID: String? = nil) async {
        guard let selectedSessionID, let source, selectedSession?.state != .ended else { return }
        let requestKey = selectedSessionID + ":" + (requestID ?? "__default__")
        guard !answeringRequestKeys.contains(requestKey),
              !answeredRequestKeysBySession[selectedSessionID, default: []].contains(requestKey)
        else { return }
        answeringRequestKeys.insert(requestKey)
        let generation = sourceGeneration
        defer {
            if generation == sourceGeneration {
                answeringRequestKeys.remove(requestKey)
            }
        }
        do {
            try await source.answer(optionIndex: optionIndex, requestID: requestID, sessionID: selectedSessionID)
            guard generation == sourceGeneration else { return }
            answeredRequestKeysBySession[selectedSessionID, default: []].insert(requestKey)
        } catch {
            guard generation == sourceGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func clearError() { errorMessage = nil }

    private func loadAndObserve(source: any AgentChatSessionSource, generation: Int) async {
        guard !Task.isCancelled, generation == sourceGeneration else { return }
        await loadSessions(source: source, generation: generation)
        guard !Task.isCancelled, generation == sourceGeneration else { return }
        await observeHostEvents(source: source, generation: generation)
    }

    private func observeHostEvents(source: any AgentChatSessionSource, generation: Int) async {
        var reconnectAttempt = 0
        while !Task.isCancelled, generation == sourceGeneration {
            let stream = await source.sessionEvents()
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            connectionState = .connected
            reconnectAttempt = 0
            for await frame in stream {
                guard !Task.isCancelled, generation == sourceGeneration else { return }
                apply(frame.event, to: frame.sessionID)
                if frame.event.eventIsDescriptorChange {
                    if let descriptor = try? await source.session(sessionID: frame.sessionID) {
                        guard !Task.isCancelled, generation == sourceGeneration else { return }
                        upsert(descriptor)
                    }
                }
            }
            guard generation == sourceGeneration, !Task.isCancelled else { return }
            connectionState = .reconnecting
            reconnectAttempt += 1
            await reconnectDelay(reconnectAttempt)
            guard generation == sourceGeneration, !Task.isCancelled else { return }
            // Reconcile the session snapshot and transcript after an EOF. The
            // stream has no replay cursor, so events published while it was
            // down can only be recovered from the host's authoritative state.
            await loadSessions(source: source, generation: generation)
            guard generation == sourceGeneration, !Task.isCancelled else { return }
            if let selectedSessionID {
                await loadHistory(
                    sessionID: selectedSessionID,
                    source: source,
                    reset: true,
                    generation: generation
                )
            }
        }
    }

    private func loadSessions(source: any AgentChatSessionSource, generation: Int? = nil) async {
        do {
            let loaded = try await source.sessions(workspaceID: nil)
            guard !Task.isCancelled,
                  generation.map({ $0 == sourceGeneration }) ?? true else { return }
            let currentByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
            let reconciled = loaded.compactMap { descriptor -> ChatSessionDescriptor? in
                if let removedVersion = removedSessionVersions[descriptor.id],
                   descriptor.version <= removedVersion {
                    return nil
                }
                // A snapshot can have started before a newer live descriptor
                // event arrived. Keep the newer in-memory value in that case.
                if let current = currentByID[descriptor.id], current.version > descriptor.version {
                    return current
                }
                return descriptor
            }
            for descriptor in reconciled {
                if let removedVersion = removedSessionVersions[descriptor.id],
                   descriptor.version > removedVersion {
                    removedSessionVersions.removeValue(forKey: descriptor.id)
                }
            }
            sessions = reconciled.sorted(by: Self.sortSessions)
            if selectedSessionID == nil, let first = sessions.first {
                select(first)
            } else if let selectedSessionID,
                      !sessions.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = nil
                if let first = sessions.first {
                    select(first)
                }
            }
            connectionState = .connected
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  generation.map({ $0 == sourceGeneration }) ?? true else { return }
            connectionState = .reconnecting
            errorMessage = error.localizedDescription
        }
    }

    private func loadHistory(
        sessionID: String,
        source: any AgentChatSessionSource,
        reset: Bool,
        generation: Int? = nil
    ) async {
        guard !loadingSessionIDs.contains(sessionID) else { return }
        loadingSessionIDs.insert(sessionID)
        defer { loadingSessionIDs.remove(sessionID) }
        do {
            var resetRequest = reset
            while true {
                let before = resetRequest ? nil : historyCursors[sessionID]
                let revisionAtStart = transcriptRevisions[sessionID, default: 0]
                let resetTokenAtStart = historyResetTokens[sessionID, default: 0]
                let page = try await source.history(sessionID: sessionID, beforeSeq: before, limit: 80)
                guard !Task.isCancelled,
                      generation.map({ $0 == sourceGeneration }) ?? true else { return }
                // A removal can race this RPC. The session's transcript was
                // purged in that case, so do not retry the request or restore
                // state for a session that is no longer in the live list.
                guard sessions.contains(where: { $0.id == sessionID }) else { return }

                // A reset can arrive while this RPC is in flight. Re-anchor
                // the request to the new sequence space instead of applying a
                // page from the old transcript over the reset state.
                if resetTokenAtStart != historyResetTokens[sessionID, default: 0] {
                    resetRequest = true
                    continue
                }

                if resetRequest {
                    let current = messagesBySession[sessionID] ?? []
                    if revisionAtStart != transcriptRevisions[sessionID, default: 0] {
                        // Live events delivered during the RPC win over stale
                        // duplicate values from the history response.
                        messagesBySession[sessionID] = mergeMessages(page.messages, current)
                        terminalBlocksBySession[sessionID] = mergeTerminalBlocks(
                            page.terminalBlocks ?? [],
                            terminalBlocksBySession[sessionID] ?? []
                        )
                    } else {
                        messagesBySession[sessionID] = page.messages
                        terminalBlocksBySession[sessionID] = page.terminalBlocks ?? []
                    }
                } else {
                    messagesBySession[sessionID] = mergeMessages(
                        page.messages,
                        messagesBySession[sessionID] ?? []
                    )
                    if let blocks = page.terminalBlocks {
                        terminalBlocksBySession[sessionID] = mergeTerminalBlocks(
                            blocks,
                            terminalBlocksBySession[sessionID] ?? []
                        )
                    }
                }
                historyCursors[sessionID] = page.messages.first?.seq
                // The host can report that older transcript lines exist on
                // disk even when they have fallen outside its bounded cache.
                // An empty page has no cursor to advance, so retaining
                // `hasMore` would make every tap request the newest page
                // again forever.
                historyHasMore[sessionID] = page.hasMore && !page.messages.isEmpty
                break
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  generation.map({ $0 == sourceGeneration }) ?? true else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func observe(
        sessionID: String,
        source: any AgentChatSessionSource,
        generation: Int
    ) async {
        var reconnectAttempt = 0
        while !Task.isCancelled,
              generation == sourceGeneration,
              selectedSessionID == sessionID {
            let stream = await source.events(sessionID: sessionID)
            guard !Task.isCancelled,
                  generation == sourceGeneration,
                  selectedSessionID == sessionID else { return }
            reconnectAttempt = 0
            for await event in stream {
                guard !Task.isCancelled,
                      generation == sourceGeneration,
                      selectedSessionID == sessionID else { return }
                apply(event, to: sessionID)
            }
            guard !Task.isCancelled,
                  generation == sourceGeneration,
                  selectedSessionID == sessionID else { return }
            reconnectAttempt += 1
            await reconnectDelay(reconnectAttempt)
            guard !Task.isCancelled,
                  generation == sourceGeneration,
                  selectedSessionID == sessionID else { return }
            // Session streams do not replay missed events after EOF. Reload
            // the transcript before subscribing again so the next stream
            // starts from a complete, current sequence.
            await loadHistory(
                sessionID: sessionID,
                source: source,
                reset: true,
                generation: generation
            )
        }
    }

    private func apply(_ event: ChatSessionEvent, to sessionID: String) {
        switch event {
        case .appended(let messages): upsertMessages(messages, sessionID: sessionID)
        case .updated(let messages): upsertMessages(messages, sessionID: sessionID)
        case .streamingProse(let message): streamingBySession[sessionID] = message
        case .stateChanged(let state):
            guard let old = sessions.first(where: { $0.id == sessionID }) else { return }
            upsert(old.withState(state))
        case .descriptorChanged(let descriptor): upsert(descriptor)
        case .sessionRemoved:
            let version: Int
            if case .sessionRemoved(let removedVersion) = event {
                version = removedVersion
            } else {
                version = Int.max
            }
            if let current = sessions.first(where: { $0.id == sessionID }), version < current.version {
                return
            }
            removedSessionVersions[sessionID] = max(version, removedSessionVersions[sessionID] ?? Int.min)
            sessionTasks[sessionID]?.cancel()
            sessionTasks[sessionID] = nil
            historyReloadTasks[sessionID]?.cancel()
            historyReloadTasks[sessionID] = nil
            sessions.removeAll { $0.id == sessionID }
            messagesBySession[sessionID] = nil
            terminalBlocksBySession[sessionID] = nil
            streamingBySession[sessionID] = nil
            historyCursors[sessionID] = nil
            historyHasMore[sessionID] = nil
            transcriptRevisions[sessionID] = nil
            historyResetTokens[sessionID] = nil
            pendingSendsBySession[sessionID] = nil
            answeredRequestKeysBySession[sessionID] = nil
            answeringRequestKeys = answeringRequestKeys.filter { !$0.hasPrefix("\(sessionID):") }
            sendingSessionIDs.remove(sessionID)
            interruptingSessionIDs.remove(sessionID)
            if selectedSessionID == sessionID {
                if let next = sessions.first {
                    select(next)
                } else {
                    selectedSessionID = nil
                }
            }
        case .terminalBlocks:
            if case .terminalBlocks(let blocks) = event {
                transcriptRevisions[sessionID, default: 0] &+= 1
                var byID = Dictionary(
                    uniqueKeysWithValues: (terminalBlocksBySession[sessionID] ?? []).map { ($0.id, $0) }
                )
                for block in blocks { byID[block.id] = block }
                terminalBlocksBySession[sessionID] = byID.values.sorted { $0.id < $1.id }
            }
        case .reset:
            transcriptRevisions[sessionID, default: 0] &+= 1
            historyResetTokens[sessionID, default: 0] &+= 1
            answeredRequestKeysBySession[sessionID] = nil
            answeringRequestKeys = answeringRequestKeys.filter { !$0.hasPrefix("\(sessionID):") }
            messagesBySession[sessionID] = []
            terminalBlocksBySession[sessionID] = []
            streamingBySession[sessionID] = nil
            historyCursors[sessionID] = nil
            historyHasMore[sessionID] = nil
            if selectedSessionID == sessionID, let source {
                let generation = sourceGeneration
                historyReloadTasks[sessionID]?.cancel()
                historyReloadTasks[sessionID] = Task { [weak self] in
                    await self?.loadHistory(
                        sessionID: sessionID,
                        source: source,
                        reset: true,
                        generation: generation
                    )
                }
            }
        case .unknown:
            break
        }
    }

    private func upsertMessages(_ messages: [ChatMessage], sessionID: String) {
        transcriptRevisions[sessionID, default: 0] &+= 1
        var current = messagesBySession[sessionID] ?? []
        var byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        for message in messages { byID[message.id] = message }
        current = byID.values.sorted { $0.seq < $1.seq }
        messagesBySession[sessionID] = current
        streamingBySession[sessionID] = nil
    }

    private func upsert(_ descriptor: ChatSessionDescriptor) {
        if let index = sessions.firstIndex(where: { $0.id == descriptor.id }) {
            guard descriptor.version >= sessions[index].version else { return }
            sessions[index] = descriptor
        } else {
            if let removedVersion = removedSessionVersions[descriptor.id], descriptor.version <= removedVersion {
                return
            }
            sessions.append(descriptor)
        }
        sessions.sort(by: Self.sortSessions)
    }

    private func drainSendQueue(
        sessionID: String,
        source: any AgentChatSessionSource,
        generation: Int
    ) async {
        guard sendingSessionIDs.insert(sessionID).inserted else { return }
        defer { sendingSessionIDs.remove(sessionID) }

        while let queued = pendingSendsBySession[sessionID]?.first {
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            pendingSendsBySession[sessionID]?.removeFirst()
            do {
                try await source.send(
                    text: queued.text,
                    attachments: queued.attachments.map(\.outbound),
                    sessionID: sessionID
                )
            } catch {
                guard generation == sourceGeneration, !Task.isCancelled else { return }
                pendingSendsBySession[sessionID, default: []].insert(queued, at: 0)
                if selectedSessionID == sessionID,
                   draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   attachments.isEmpty {
                    draft = queued.text
                    attachments = queued.attachments
                }
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    private static func sortSessions(_ lhs: ChatSessionDescriptor, _ rhs: ChatSessionDescriptor) -> Bool {
        if lhs.state.needsAttention != rhs.state.needsAttention { return lhs.state.needsAttention }
        return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
    }

    private func mergeMessages(_ page: [ChatMessage], _ current: [ChatMessage]) -> [ChatMessage] {
        var byID = Dictionary(uniqueKeysWithValues: page.map { ($0.id, $0) })
        for message in current { byID[message.id] = message }
        return byID.values.sorted { $0.seq < $1.seq }
    }

    private func mergeTerminalBlocks(
        _ page: [TerminalCommandBlock],
        _ current: [TerminalCommandBlock]
    ) -> [TerminalCommandBlock] {
        var byID = Dictionary(uniqueKeysWithValues: page.map { ($0.id, $0) })
        for block in current { byID[block.id] = block }
        return byID.values.sorted { $0.id < $1.id }
    }

}

private extension ChatSessionEvent {
    var eventIsDescriptorChange: Bool {
        if case .descriptorChanged = self { return true }
        return false
    }
}

private extension ChatSessionDescriptor {
    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }
}
