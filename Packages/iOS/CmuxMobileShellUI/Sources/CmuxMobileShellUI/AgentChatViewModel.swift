#if os(iOS)
import CmuxAgentChat
import CmuxMobileShell
import Foundation
import Observation

/// A local attachment staged in the ChatGPT-style composer.
///
/// The host protocol intentionally carries only encoded image bytes. Keeping
/// the draft here lets the UI show a thumbnail and lets a failed send restore
/// the exact payload without touching the transcript reducer.
struct AgentChatDraftAttachment: Identifiable, Equatable, Sendable {
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
        thumbnailData: Data?
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

/// Main-actor owner for one native agent conversation.
@MainActor
@Observable
final class AgentChatViewModel {
    let source: MobileChatEventSource?
    let workspaceID: String?
    let preferredTerminalID: String?

    var sessions: [ChatSessionDescriptor] = []
    var selectedSessionID: String?
    var timeline: AgentChatTimelineState?
    var composerText = ""
    var pendingAttachments: [AgentChatDraftAttachment] = []
    var isLoadingSessions = false
    var isSending = false
    var isInterrupting = false
    var errorMessage: String?

    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var sessionEventsTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var didStart = false

    init(
        source: MobileChatEventSource?,
        workspaceID: String?,
        preferredTerminalID: String?
    ) {
        self.source = source
        self.workspaceID = workspaceID
        self.preferredTerminalID = preferredTerminalID
    }

    deinit {
        eventsTask?.cancel()
        sessionEventsTask?.cancel()
        historyTask?.cancel()
    }

    var selectedSession: ChatSessionDescriptor? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    var state: ChatAgentState {
        timeline?.descriptor.state ?? selectedSession?.state ?? .idle
    }

    var canSend: Bool {
        source != nil
            && selectedSessionID != nil
            && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingAttachments.isEmpty)
            && !isSending
            && state != .ended
    }

    var canInterrupt: Bool {
        guard case .working = state else { return false }
        return !isInterrupting
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        startSessionEvents()
        refreshSessions()
    }

    private func startSessionEvents() {
        guard let source else { return }
        let requestedWorkspaceID = workspaceID
        sessionEventsTask?.cancel()
        sessionEventsTask = Task { [weak self, source] in
            let stream = await source.sessionEvents()
            for await frame in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.applySessionFrame(frame, workspaceID: requestedWorkspaceID)
            }
        }
    }

    func refreshSessions() {
        guard let source else {
            sessions = []
            isLoadingSessions = false
            return
        }
        // Capture values before entering the task. This keeps the task's
        // sendable boundary explicit under Swift 6 isolation.
        let requestedWorkspaceID = workspaceID
        let preferredTerminalID = self.preferredTerminalID
        isLoadingSessions = true
        Task { [weak self, source] in
            do {
                var loaded = try await source.sessions(workspaceID: requestedWorkspaceID)
                if let preferredTerminalID {
                    loaded = loaded.filter { $0.terminalID == preferredTerminalID }
                    if loaded.isEmpty {
                        loaded = try await source.sessions(workspaceID: nil).filter {
                            $0.terminalID == preferredTerminalID
                        }
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.sessions = loaded.sorted(by: Self.sessionSort)
                self.isLoadingSessions = false
                if let selected = self.selectedSessionID,
                   self.sessions.contains(where: { $0.id == selected }) {
                    return
                }
                let preferred = self.sessions.first { $0.terminalID == preferredTerminalID }
                self.select(preferred ?? ChatSessionDescriptor.openable(self.sessions).first)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoadingSessions = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func select(_ descriptor: ChatSessionDescriptor?) {
        guard let descriptor else {
            selectedSessionID = nil
            timeline = nil
            eventsTask?.cancel()
            historyTask?.cancel()
            return
        }
        guard selectedSessionID != descriptor.id else { return }
        selectedSessionID = descriptor.id
        errorMessage = nil
        timeline = AgentChatTimelineState(descriptor: descriptor)
        eventsTask?.cancel()
        historyTask?.cancel()
        guard let source else { return }

        let sessionID = descriptor.id
        eventsTask = Task { [weak self] in
            let stream = await source.events(sessionID: sessionID)
            for await event in stream {
                guard !Task.isCancelled else { return }
                self?.apply(event, for: sessionID)
            }
            guard !Task.isCancelled else { return }
            self?.errorMessage = "Live updates paused. Reconnect the Mac to resume."
        }
        loadHistory(for: sessionID, beforeSeq: nil, prepending: false)
    }

    /// Selects the most useful live conversation for a provider picker. The
    /// host keeps provider identity in the open `agent_kind` string, so this
    /// also matches forward-compatible OpenCode values carried as `other`.
    func selectFirstSession(sourceName: String) {
        let matching = sessions.filter {
            $0.agentKind.sourceName.caseInsensitiveCompare(sourceName) == .orderedSame
        }
        select(ChatSessionDescriptor.openable(matching).first)
    }

    func loadOlderHistory() {
        guard let sessionID = selectedSessionID,
              let timeline,
              timeline.hasMoreHistory,
              !timeline.isLoadingHistory,
              let firstSeq = timeline.messages.first?.seq else { return }
        loadHistory(for: sessionID, beforeSeq: firstSeq, prepending: true)
    }

    func addAttachment(_ attachment: AgentChatDraftAttachment) {
        guard pendingAttachments.count < 8 else { return }
        let currentBytes = pendingAttachments.reduce(0) { $0 + $1.data.count }
        guard currentBytes + attachment.data.count <= 8 * 1024 * 1024 else { return }
        pendingAttachments.append(attachment)
    }

    func removeAttachment(id: AgentChatDraftAttachment.ID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    func clearComposer() {
        composerText = ""
        pendingAttachments = []
    }

    func send() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let drafts = pendingAttachments
        guard (!text.isEmpty || !drafts.isEmpty), let source, let sessionID = selectedSessionID, !isSending else { return }
        clearComposer()
        isSending = true
        errorMessage = nil
        Task { [weak self] in
            do {
                try await source.send(
                    text: text,
                    attachments: drafts.map(\.outbound),
                    sessionID: sessionID
                )
                guard let self, !Task.isCancelled else { return }
                self.isSending = false
                if let current = self.timeline?.descriptor {
                    self.timeline?.descriptor = current.withState(.working(since: Date()))
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isSending = false
                self.errorMessage = error.localizedDescription
                self.composerText = text
                self.pendingAttachments = drafts + self.pendingAttachments
            }
        }
    }

    func interrupt(hard: Bool = false) {
        guard let source, let sessionID = selectedSessionID, canInterrupt else { return }
        isInterrupting = true
        Task { [weak self] in
            do {
                try await source.interrupt(sessionID: sessionID, hard: hard)
                self?.isInterrupting = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isInterrupting = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func answer(optionIndex: Int) {
        guard let source, let sessionID = selectedSessionID else { return }
        Task { [weak self] in
            do {
                try await source.answer(optionIndex: optionIndex, sessionID: sessionID)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func loadHistory(for sessionID: String, beforeSeq: Int?, prepending: Bool) {
        guard let source else { return }
        timeline?.isLoadingHistory = true
        historyTask?.cancel()
        historyTask = Task { [weak self] in
            do {
                let page = try await source.history(sessionID: sessionID, beforeSeq: beforeSeq, limit: 80)
                guard let self, !Task.isCancelled, self.selectedSessionID == sessionID else { return }
                self.timeline?.mergeHistory(page, prepending: prepending)
            } catch {
                guard let self, !Task.isCancelled, self.selectedSessionID == sessionID else { return }
                self.timeline?.applyError(error)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ event: ChatSessionEvent, for sessionID: String) {
        guard selectedSessionID == sessionID else { return }
        timeline?.apply(event)
        if case .descriptorChanged(let descriptor) = event {
            if let index = sessions.firstIndex(where: { $0.id == sessionID }),
               descriptor.version >= sessions[index].version {
                sessions[index] = descriptor
            }
        } else if case .stateChanged(let state) = event,
                  let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index] = sessions[index].withState(state)
        }
    }

    private func applySessionFrame(
        _ frame: ChatSessionEventFrame,
        workspaceID requestedWorkspaceID: String?
    ) {
        switch frame.event {
        case .descriptorChanged(let descriptor):
            guard requestedWorkspaceID == nil || descriptor.workspaceID == requestedWorkspaceID else { return }
            guard preferredTerminalID == nil || descriptor.terminalID == preferredTerminalID else { return }
            if let index = sessions.firstIndex(where: { $0.id == descriptor.id }) {
                guard descriptor.version >= sessions[index].version else { return }
                sessions[index] = descriptor
                if selectedSessionID == descriptor.id {
                    timeline?.apply(.descriptorChanged(descriptor))
                }
            } else {
                sessions.append(descriptor)
                sessions.sort(by: Self.sessionSort)
            }
            if selectedSessionID == nil {
                select(ChatSessionDescriptor.openable(sessions).first)
            }
        case .stateChanged(let state):
            guard let index = sessions.firstIndex(where: { $0.id == frame.sessionID }) else { return }
            sessions[index] = sessions[index].withState(state)
            if selectedSessionID == frame.sessionID {
                timeline?.apply(.stateChanged(state))
            }
        case .sessionRemoved:
            guard let index = sessions.firstIndex(where: { $0.id == frame.sessionID }) else { return }
            let wasSelected = selectedSessionID == frame.sessionID
            sessions.remove(at: index)
            if wasSelected {
                eventsTask?.cancel()
                historyTask?.cancel()
                selectedSessionID = nil
                timeline = nil
                select(ChatSessionDescriptor.openable(sessions).first)
            }
        default:
            break
        }
    }

    private static func sessionSort(_ lhs: ChatSessionDescriptor, _ rhs: ChatSessionDescriptor) -> Bool {
        let lhsPriority = statePriority(lhs.state)
        let rhsPriority = statePriority(rhs.state)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
    }

    private static func statePriority(_ state: ChatAgentState) -> Int {
        switch state {
        case .needsInput: 0
        case .working: 1
        case .idle: 2
        case .ended: 3
        }
    }
}
#endif
