import CmuxAgentChat
import CmuxMobileShell
import Foundation
import Observation

/// The iOS state machine for the first-class agent chat surface.
///
/// This object deliberately owns transport tasks rather than letting views
/// subscribe directly. A tab switch therefore cannot leave a listener behind,
/// and a reconnect can rebuild the session list and the selected transcript
/// without losing the draft.
@MainActor
@Observable
final class MobileChatStore {
    typealias SourceProvider = () -> MobileChatEventSource?

    private static let selectedSessionKey = "cmux.mobile.chat.selectedSession.v1"
    private static let historyPageSize = 80

    private let sourceProvider: SourceProvider
    private var sessionEventsTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    /// Invalidates the session-list stream and action requests when the
    /// connection lifecycle is rebuilt.
    private var operationGeneration: UInt64 = 0
    /// Transcript work has a shorter lifetime than the session-list stream.
    /// Selecting a different chat must cancel history/events without making a
    /// still-valid session-list listener stop consuming descriptor pushes.
    private var transcriptGeneration: UInt64 = 0
    /// Separately invalidates prompt sends when the user changes sessions or
    /// the connection is rebuilt. A global `isSending` flag must never be
    /// cleared by a completion belonging to another conversation.
    private var sendGeneration: UInt64 = 0
    private var reconciler = ChatSessionReconciler()
    private var messageByID: [String: ChatMessage] = [:]
    private var blockByID: [Int: TerminalCommandBlock] = [:]
    /// The local row shown while a prompt is in flight. The host publishes an
    /// authoritative user row asynchronously; keeping this identity lets the
    /// reducer replace the optimistic row instead of rendering both copies.
    private var pendingOptimisticMessageID: String?
    private var pendingOptimisticText: String?

    private(set) var sessions: [ChatSessionDescriptor] = []
    private(set) var selectedSessionID: String?
    private(set) var messages: [ChatMessage] = []
    private(set) var terminalBlocks: [TerminalCommandBlock] = []
    private(set) var streamingProse: ChatMessage?
    private(set) var hasMoreHistory = false
    private(set) var isLoading = false
    private(set) var isLoadingOlder = false
    private(set) var isSending = false
    private(set) var isConnected = false
    private(set) var errorMessage: String?
    var draft = ""
    var stagedAttachments: [ChatOutboundAttachment] = []

    init(sourceProvider: @escaping SourceProvider) {
        self.sourceProvider = sourceProvider
        selectedSessionID = UserDefaults.standard.string(forKey: Self.selectedSessionKey)
    }

    func start() {
        guard sessionEventsTask == nil else { return }
        sessionEventsTask = Task { [weak self] in
            await self?.runSessionLifecycle()
        }
    }

    func stop() {
        operationGeneration &+= 1
        transcriptGeneration &+= 1
        invalidateSend()
        sessionEventsTask?.cancel()
        transcriptTask?.cancel()
        sessionEventsTask = nil
        transcriptTask = nil
        isConnected = false
    }

    /// Restarts all chat streams against the current Mac connection. The
    /// shell's connection generation changes when the RPC client is replaced,
    /// so a mounted Chat destination can recover without a tab switch.
    func restart() {
        stop()
        start()
    }

    func refresh() {
        stop()
        start()
    }

    func selectSession(_ id: String) {
        guard selectedSessionID != id else { return }
        invalidateSend()
        // Composer state belongs to the conversation being viewed. Clear it
        // on a real selection change so a draft or attachment cannot be sent
        // to the newly selected agent by accident.
        draft = ""
        stagedAttachments = []
        selectedSessionID = id
        UserDefaults.standard.set(id, forKey: Self.selectedSessionKey)
        beginTranscript(id: id)
    }

    func selectSession(_ descriptor: ChatSessionDescriptor) {
        selectSession(descriptor.id)
    }

    /// Re-reads the selected transcript while keeping the session-list
    /// listener alive. This is used by the conversation menu and is distinct
    /// from `refresh()`, which rebuilds the connection-wide session stream.
    func refreshTranscript() {
        guard let selectedSessionID else { return }
        beginTranscript(id: selectedSessionID)
    }

    func loadOlderHistory() {
        guard !isLoadingOlder,
              hasMoreHistory,
              let sessionID = selectedSessionID,
              let before = messages.first?.seq,
              let source = sourceProvider() else { return }
        isLoadingOlder = true
        let generation = transcriptGeneration
        Task { [weak self] in
            defer {
                if let self,
                   generation == self.transcriptGeneration,
                   self.selectedSessionID == sessionID {
                    self.isLoadingOlder = false
                }
            }
            do {
                let page = try await source.history(
                    sessionID: sessionID,
                    beforeSeq: before,
                    limit: Self.historyPageSize
                )
                guard let self,
                      generation == self.transcriptGeneration,
                      self.selectedSessionID == sessionID else { return }
                self.merge(page: page, replacing: false)
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.transcriptGeneration else { return }
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !stagedAttachments.isEmpty),
              let sessionID = selectedSessionID,
              sessions.first(where: { $0.id == sessionID })?.state != .ended,
              let source = sourceProvider(),
              !isSending else { return }
        draft = ""
        let attachments = stagedAttachments
        stagedAttachments = []
        sendGeneration &+= 1
        let sendGeneration = sendGeneration
        isSending = true
        errorMessage = nil
        // The host will publish the authoritative row. This optimistic row
        // keeps the composer responsive while a remote Mac is waking up.
        if !text.isEmpty {
            let optimisticID = "local-\(UUID().uuidString)"
            pendingOptimisticMessageID = optimisticID
            pendingOptimisticText = text
            appendOptimistic(
                ChatMessage(
                    id: optimisticID,
                    seq: (messages.last?.seq ?? 0) + 1,
                    role: .user,
                    timestamp: Date(),
                    kind: .prose(ChatProse(text: text))
                )
            )
        }
        sendTask = Task { [weak self] in
            defer {
                if let self, self.sendGeneration == sendGeneration {
                    self.isSending = false
                    self.sendTask = nil
                }
            }
            do {
                try await source.send(text: text, attachments: attachments, sessionID: sessionID)
                guard let self,
                      sendGeneration == self.sendGeneration,
                      self.selectedSessionID == sessionID else { return }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      sendGeneration == self.sendGeneration,
                      self.selectedSessionID == sessionID else { return }
                self.errorMessage = Self.message(for: error)
                self.removePendingOptimisticMessage()
                self.draft = text
                self.stagedAttachments = attachments
            }
        }
    }

    func interrupt(hard: Bool = false) {
        guard let sessionID = selectedSessionID,
              let descriptor = sessions.first(where: { $0.id == sessionID }),
              descriptor.state != .ended,
              let source = sourceProvider() else { return }
        let generation = operationGeneration
        Task { [weak self] in
            do {
                try await source.interrupt(sessionID: sessionID, hard: hard)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == self.operationGeneration,
                      self.selectedSessionID == sessionID else { return }
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    func answer(optionIndex: Int) {
        guard let sessionID = selectedSessionID,
              sessions.first(where: { $0.id == sessionID })?.state != .ended,
              let source = sourceProvider() else { return }
        let generation = operationGeneration
        Task { [weak self] in
            do {
                try await source.answer(optionIndex: optionIndex, sessionID: sessionID)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == self.operationGeneration,
                      self.selectedSessionID == sessionID else { return }
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    private func runSessionLifecycle() async {
        operationGeneration &+= 1
        let generation = operationGeneration
        defer {
            if generation == operationGeneration {
                // An AsyncStream finishing is the transport's reconnect
                // signal. Clear the handle so the next connection generation
                // or foreground start can install a fresh listener.
                sessionEventsTask = nil
            }
        }
        guard let source = sourceProvider() else {
            isConnected = false
            isLoading = false
            errorMessage = "Connect to a Mac to use agent chat."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            // Install the listener before the authoritative pull. This closes
            // the gap where a new agent could start between the list request
            // and event subscription; the reconciler preserves pushes that
            // arrive after the snapshot cursor.
            let stream = await source.sessionEvents()
            let eventPump = Task { @MainActor [weak self] in
                for await frame in stream {
                    guard let self,
                          !Task.isCancelled,
                          generation == self.operationGeneration else { return }
                    self.applySessionFrame(frame)
                }
            }
            defer { eventPump.cancel() }
            let snapshotRevision = reconciler.snapshotRevision
            let incoming = try await source.sessions(workspaceID: nil)
            guard generation == operationGeneration else { return }
            reconciler.replace(with: incoming, capturedAt: snapshotRevision)
            publishSessions()
            isConnected = true
            isLoading = false
            let restored = selectedSessionID.flatMap { id in
                reconciler.descriptor(for: id)?.id
            }
            let target = restored ?? sessions.first?.id
            if restored == nil, selectedSessionID != nil {
                selectedSessionID = nil
                UserDefaults.standard.removeObject(forKey: Self.selectedSessionKey)
            }
            if let target {
                if selectedSessionID != target {
                    selectedSessionID = target
                    UserDefaults.standard.set(target, forKey: Self.selectedSessionKey)
                }
                beginTranscript(id: target)
            } else {
                messages = []
                terminalBlocks = []
                streamingProse = nil
            }
            await withTaskCancellationHandler {
                await eventPump.value
            } onCancel: {
                eventPump.cancel()
            }
            guard generation == operationGeneration else { return }
            isConnected = false
        } catch is CancellationError {
            return
        } catch {
            guard generation == operationGeneration else { return }
            isConnected = false
            isLoading = false
            errorMessage = Self.message(for: error)
        }
    }

    private func beginTranscript(id: String) {
        transcriptTask?.cancel()
        transcriptGeneration &+= 1
        let generation = transcriptGeneration
        messages = []
        terminalBlocks = []
        messageByID = [:]
        blockByID = [:]
        pendingOptimisticMessageID = nil
        pendingOptimisticText = nil
        streamingProse = nil
        hasMoreHistory = false
        isLoadingOlder = false
        isLoading = true
        errorMessage = nil
        guard let source = sourceProvider() else {
            isConnected = false
            isLoading = false
            errorMessage = "Connect to a Mac to open this conversation."
            return
        }
        transcriptTask = Task { [weak self] in
            do {
                // Subscribe before pulling history so an event arriving during
                // the pull remains buffered by AsyncStream and is not lost.
                let stream = await source.events(sessionID: id)
                let page = try await source.history(
                    sessionID: id,
                    beforeSeq: nil,
                    limit: Self.historyPageSize
                )
                guard let self,
                      generation == self.transcriptGeneration,
                      self.selectedSessionID == id else { return }
                self.merge(page: page, replacing: true)
                self.isLoading = false
                for await event in stream {
                    guard !Task.isCancelled,
                          generation == self.transcriptGeneration,
                          self.selectedSessionID == id else { return }
                    self.apply(event: event, sessionID: id)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == self.transcriptGeneration,
                      self.selectedSessionID == id else { return }
                self.isLoading = false
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    private func applySessionFrame(_ frame: ChatSessionEventFrame) {
        if case .sessionRemoved(let version) = frame.event {
            applySessionRemoval(sessionID: frame.sessionID, version: version)
            return
        }
        _ = reconciler.apply(sessionID: frame.sessionID, event: frame.event)
        publishSessions()
    }

    private func apply(event: ChatSessionEvent, sessionID: String) {
        switch event {
        case .appended(let incoming), .updated(let incoming):
            for message in incoming { messageByID[message.id] = message }
            reconcilePendingOptimisticMessage(with: incoming)
            messages = messageByID.values.sorted { lhs, rhs in
                lhs.seq == rhs.seq ? lhs.id < rhs.id : lhs.seq < rhs.seq
            }
            if incoming.contains(where: { message in
                if case .prose = message.kind { return message.role == .agent }
                return false
            }) {
                streamingProse = nil
            }
        case .stateChanged(let state, let version):
            if reconciler.apply(sessionID: sessionID, event: .stateChanged(state, version: version)) {
                publishSessions()
            }
        case .descriptorChanged(let descriptor):
            _ = reconciler.upsert(descriptor)
            publishSessions()
        case .streamingProse(let preview):
            streamingProse = preview
        case .terminalBlocks(let blocks):
            for block in blocks { blockByID[block.id] = block }
            terminalBlocks = blockByID.values.sorted { $0.id < $1.id }
        case .reset:
            beginTranscript(id: sessionID)
        case .sessionRemoved(let version):
            applySessionRemoval(sessionID: sessionID, version: version)
        case .unknown:
            break
        }
    }

    private func merge(page: ChatHistoryPage, replacing: Bool) {
        if replacing {
            messageByID = [:]
            blockByID = [:]
            pendingOptimisticMessageID = nil
            pendingOptimisticText = nil
        }
        for message in page.messages { messageByID[message.id] = message }
        for block in page.terminalBlocks ?? [] { blockByID[block.id] = block }
        messages = messageByID.values.sorted { lhs, rhs in
            lhs.seq == rhs.seq ? lhs.id < rhs.id : lhs.seq < rhs.seq
        }
        terminalBlocks = blockByID.values.sorted { $0.id < $1.id }
        hasMoreHistory = page.hasMore
    }

    private func appendOptimistic(_ message: ChatMessage) {
        messageByID[message.id] = message
        messages = messageByID.values.sorted { lhs, rhs in
            lhs.seq == rhs.seq ? lhs.id < rhs.id : lhs.seq < rhs.seq
        }
    }

    private func reconcilePendingOptimisticMessage(with incoming: [ChatMessage]) {
        guard let pendingID = pendingOptimisticMessageID,
              let pendingText = pendingOptimisticText else { return }
        let receivedAuthoritativeRow = incoming.contains { message in
            guard message.role == .user else { return false }
            guard case .prose(let prose) = message.kind else { return false }
            return prose.text == pendingText
        }
        guard receivedAuthoritativeRow else { return }
        messageByID.removeValue(forKey: pendingID)
        pendingOptimisticMessageID = nil
        pendingOptimisticText = nil
    }

    private func removePendingOptimisticMessage() {
        if let pendingOptimisticMessageID {
            messageByID.removeValue(forKey: pendingOptimisticMessageID)
            messages = messageByID.values.sorted { lhs, rhs in
                lhs.seq == rhs.seq ? lhs.id < rhs.id : lhs.seq < rhs.seq
            }
        }
        pendingOptimisticMessageID = nil
        pendingOptimisticText = nil
    }

    private func publishSessions() {
        sessions = reconciler.descriptors
    }

    private func applySessionRemoval(sessionID: String, version: Int) {
        let wasSelected = selectedSessionID == sessionID
        let didApply = reconciler.apply(
            sessionID: sessionID,
            event: .sessionRemoved(version: version)
        )
        guard didApply else { return }
        if wasSelected {
            selectedSessionID = nil
            invalidateSend()
        }
        publishSessions()
        guard wasSelected else { return }
        if let replacement = sessions.first?.id {
            selectSession(replacement)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedSessionKey)
            clearTranscript()
        }
    }

    private func clearTranscript() {
        transcriptTask?.cancel()
        transcriptTask = nil
        transcriptGeneration &+= 1
        messages = []
        terminalBlocks = []
        messageByID = [:]
        blockByID = [:]
        pendingOptimisticMessageID = nil
        pendingOptimisticText = nil
        streamingProse = nil
        hasMoreHistory = false
        isLoadingOlder = false
        isLoading = false
    }

    private func invalidateSend() {
        sendGeneration &+= 1
        sendTask?.cancel()
        sendTask = nil
        isSending = false
    }

    private static func message(for error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
