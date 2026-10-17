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
    private(set) var errorMessage: String?
    private(set) var attachments: [PendingAttachment] = []
    var selectedSessionID: String?
    var draft = ""
    var selectedProvider: String = "all"

    private var source: (any AgentChatSessionSource)?
    private var sourceTask: Task<Void, Never>?
    private var sessionTasks: [String: Task<Void, Never>] = [:]
    private var historyCursors: [String: Int] = [:]
    private var historyHasMore: [String: Bool] = [:]
    private var sourceGeneration = 0

    var visibleSessions: [ChatSessionDescriptor] {
        sessions.filter { selectedProvider == "all" || $0.agentKind.sourceName == selectedProvider }
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

    func updateSource(_ next: (any AgentChatSessionSource)?) {
        sourceGeneration += 1
        let generation = sourceGeneration
        sourceTask?.cancel()
        for task in sessionTasks.values { task.cancel() }
        sessionTasks = [:]
        source = next
        sessions = []
        messagesBySession = [:]
        terminalBlocksBySession = [:]
        streamingBySession = [:]
        selectedSessionID = nil
        attachments = []
        historyCursors = [:]
        historyHasMore = [:]
        guard let next else { return }
        sourceTask = Task { [weak self] in
            await self?.loadAndObserve(source: next, generation: generation)
        }
    }

    func refresh() async {
        guard let source else { return }
        await loadSessions(source: source)
        if let selectedSessionID {
            await loadHistory(sessionID: selectedSessionID, source: source, reset: true)
        }
    }

    func select(_ session: ChatSessionDescriptor) {
        selectedSessionID = session.id
        draft = ""
        attachments = []
        guard let source else { return }
        sessionTasks[session.id]?.cancel()
        sessionTasks[session.id] = Task { [weak self] in
            guard let self else { return }
            await self.loadHistory(sessionID: session.id, source: source, reset: true)
            await self.observe(sessionID: session.id, source: source)
        }
    }

    func loadOlderMessages() async {
        guard let selectedSessionID, historyHasMore[selectedSessionID] == true,
              let source else { return }
        await loadHistory(sessionID: selectedSessionID, source: source, reset: false)
    }

    func sendDraft() async {
        guard let selectedSessionID,
              let source,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              sendingSessionIDs.insert(selectedSessionID).inserted else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAttachments = attachments
        draft = ""
        attachments = []
        defer { sendingSessionIDs.remove(selectedSessionID) }
        do {
            try await source.send(
                text: text,
                attachments: pendingAttachments.map(\.outbound),
                sessionID: selectedSessionID
            )
        } catch {
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
        guard let selectedSessionID, let source else { return }
        do {
            try await source.interrupt(sessionID: selectedSessionID, hard: hard)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func answer(optionIndex: Int) async {
        guard let selectedSessionID, let source else { return }
        do {
            try await source.answer(optionIndex: optionIndex, sessionID: selectedSessionID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() { errorMessage = nil }

    private func loadAndObserve(source: any AgentChatSessionSource, generation: Int) async {
        guard generation == sourceGeneration else { return }
        await loadSessions(source: source)
        guard generation == sourceGeneration else { return }
        let stream = await source.sessionEvents()
        for await frame in stream {
            guard !Task.isCancelled, generation == sourceGeneration else { return }
            apply(frame.event, to: frame.sessionID)
            if frame.event.eventIsDescriptorChange {
                if let descriptor = try? await source.session(sessionID: frame.sessionID) {
                    upsert(descriptor)
                }
            }
        }
    }

    private func loadSessions(source: any AgentChatSessionSource) async {
        do {
            let loaded = try await source.sessions(workspaceID: nil)
            sessions = loaded.sorted(by: Self.sortSessions)
            if selectedSessionID == nil, let first = sessions.first {
                select(first)
            } else if let selectedSessionID,
                      !sessions.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = sessions.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadHistory(sessionID: String, source: any AgentChatSessionSource, reset: Bool) async {
        guard !loadingSessionIDs.contains(sessionID) else { return }
        loadingSessionIDs.insert(sessionID)
        defer { loadingSessionIDs.remove(sessionID) }
        do {
            let before = reset ? nil : historyCursors[sessionID]
            let page = try await source.history(sessionID: sessionID, beforeSeq: before, limit: 80)
            if reset {
                messagesBySession[sessionID] = page.messages
                terminalBlocksBySession[sessionID] = page.terminalBlocks ?? []
            } else {
                let current = messagesBySession[sessionID] ?? []
                let ids = Set(current.map(\.id))
                messagesBySession[sessionID] = page.messages.filter { !ids.contains($0.id) } + current
                if let blocks = page.terminalBlocks {
                    let currentBlocks = terminalBlocksBySession[sessionID] ?? []
                    let ids = Set(currentBlocks.map(\.id))
                    terminalBlocksBySession[sessionID] = blocks.filter { !ids.contains($0.id) } + currentBlocks
                }
            }
            historyCursors[sessionID] = page.messages.first?.seq
            historyHasMore[sessionID] = page.hasMore
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func observe(sessionID: String, source: any AgentChatSessionSource) async {
        let stream = await source.events(sessionID: sessionID)
        for await event in stream {
            guard !Task.isCancelled else { return }
            apply(event, to: sessionID)
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
            sessionTasks[sessionID]?.cancel()
            sessionTasks[sessionID] = nil
            sessions.removeAll { $0.id == sessionID }
            if selectedSessionID == sessionID {
                if let next = sessions.first {
                    select(next)
                } else {
                    selectedSessionID = nil
                }
            }
        case .terminalBlocks:
            if case .terminalBlocks(let blocks) = event {
                var byID = Dictionary(
                    uniqueKeysWithValues: (terminalBlocksBySession[sessionID] ?? []).map { ($0.id, $0) }
                )
                for block in blocks { byID[block.id] = block }
                terminalBlocksBySession[sessionID] = byID.values.sorted { $0.id < $1.id }
            }
        case .reset:
            messagesBySession[sessionID] = []
            terminalBlocksBySession[sessionID] = []
            streamingBySession[sessionID] = nil
            historyCursors[sessionID] = nil
            historyHasMore[sessionID] = nil
        case .unknown:
            break
        }
    }

    private func upsertMessages(_ messages: [ChatMessage], sessionID: String) {
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
            sessions.append(descriptor)
        }
        sessions.sort(by: Self.sortSessions)
    }

    private static func sortSessions(_ lhs: ChatSessionDescriptor, _ rhs: ChatSessionDescriptor) -> Bool {
        if lhs.state.needsAttention != rhs.state.needsAttention { return lhs.state.needsAttention }
        return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
    }

}

private extension ChatSessionEvent {
    var eventIsDescriptorChange: Bool {
        if case .descriptorChanged = self { return true }
        return false
    }
}
