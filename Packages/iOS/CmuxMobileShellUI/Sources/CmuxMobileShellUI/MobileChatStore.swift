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
    private var operationGeneration: UInt64 = 0
    private var reconciler = ChatSessionReconciler()
    private var messageByID: [String: ChatMessage] = [:]
    private var blockByID: [Int: TerminalCommandBlock] = [:]

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

    deinit {
        sessionEventsTask?.cancel()
        transcriptTask?.cancel()
    }

    func start() {
        guard sessionEventsTask == nil else { return }
        sessionEventsTask = Task { [weak self] in
            await self?.runSessionLifecycle()
        }
    }

    func stop() {
        operationGeneration &+= 1
        sessionEventsTask?.cancel()
        transcriptTask?.cancel()
        sessionEventsTask = nil
        transcriptTask = nil
        isConnected = false
    }

    func refresh() {
        sessionEventsTask?.cancel()
        sessionEventsTask = Task { [weak self] in
            await self?.runSessionLifecycle()
        }
    }

    func selectSession(_ id: String) {
        guard selectedSessionID != id else { return }
        selectedSessionID = id
        UserDefaults.standard.set(id, forKey: Self.selectedSessionKey)
        beginTranscript(id: id)
    }

    func selectSession(_ descriptor: ChatSessionDescriptor) {
        selectSession(descriptor.id)
    }

    func loadOlderHistory() {
        guard !isLoadingOlder,
              hasMoreHistory,
              let sessionID = selectedSessionID,
              let before = messages.first?.seq,
              let source = sourceProvider() else { return }
        isLoadingOlder = true
        let generation = operationGeneration
        Task { [weak self] in
            defer { self?.isLoadingOlder = false }
            do {
                let page = try await source.history(
                    sessionID: sessionID,
                    beforeSeq: before,
                    limit: Self.historyPageSize
                )
                guard let self,
                      generation == self.operationGeneration,
                      self.selectedSessionID == sessionID else { return }
                self.merge(page: page, replacing: false)
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.operationGeneration else { return }
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !stagedAttachments.isEmpty),
              let sessionID = selectedSessionID,
              let source = sourceProvider(),
              !isSending else { return }
        draft = ""
        let attachments = stagedAttachments
        stagedAttachments = []
        isSending = true
        errorMessage = nil
        let generation = operationGeneration
        // The host will publish the authoritative row. This optimistic row
        // keeps the composer responsive while a remote Mac is waking up.
        if !text.isEmpty {
            appendOptimistic(
                ChatMessage(
                    id: "local-\(UUID().uuidString)",
                    seq: (messages.last?.seq ?? 0) + 1,
                    role: .user,
                    timestamp: Date(),
                    kind: .prose(ChatProse(text: text))
                )
            )
        }
        Task { [weak self] in
            do {
                try await source.send(text: text, attachments: attachments, sessionID: sessionID)
                guard let self, generation == self.operationGeneration else { return }
                self.isSending = false
            } catch is CancellationError {
                guard let self, generation == self.operationGeneration else { return }
                self.isSending = false
            } catch {
                guard let self, generation == self.operationGeneration else { return }
                self.isSending = false
                self.errorMessage = Self.message(for: error)
                self.draft = text
                self.stagedAttachments = attachments
            }
        }
    }

    func interrupt(hard: Bool = false) {
        guard let sessionID = selectedSessionID, let source = sourceProvider() else { return }
        let generation = operationGeneration
        Task { [weak self] in
            do {
                try await source.interrupt(sessionID: sessionID, hard: hard)
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.operationGeneration else { return }
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    func answer(optionIndex: Int) {
        guard let sessionID = selectedSessionID, let source = sourceProvider() else { return }
        let generation = operationGeneration
        Task { [weak self] in
            do {
                try await source.answer(optionIndex: optionIndex, sessionID: sessionID)
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.operationGeneration else { return }
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    private func runSessionLifecycle() async {
        operationGeneration &+= 1
        let generation = operationGeneration
        guard let source = sourceProvider() else {
            isConnected = false
            isLoading = false
            errorMessage = "Connect to a Mac to use agent chat."
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let incoming = try await source.sessions(workspaceID: nil)
            guard generation == operationGeneration else { return }
            reconciler.replace(with: incoming)
            publishSessions()
            isConnected = true
            isLoading = false
            let restored = selectedSessionID.flatMap { id in
                reconciler.descriptor(for: id)?.id
            }
            let target = restored ?? sessions.first?.id
            if let target {
                if selectedSessionID != target {
                    selectedSessionID = target
                    UserDefaults.standard.set(target, forKey: Self.selectedSessionKey)
                }
                beginTranscript(id: target)
            }
            let stream = await source.sessionEvents()
            for await frame in stream {
                guard !Task.isCancelled, generation == operationGeneration else { return }
                applySessionFrame(frame)
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
        operationGeneration &+= 1
        let generation = operationGeneration
        messages = []
        terminalBlocks = []
        messageByID = [:]
        blockByID = [:]
        streamingProse = nil
        hasMoreHistory = false
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
                      generation == self.operationGeneration,
                      self.selectedSessionID == id else { return }
                self.merge(page: page, replacing: true)
                self.isLoading = false
                for await event in stream {
                    guard !Task.isCancelled,
                          generation == self.operationGeneration,
                          self.selectedSessionID == id else { return }
                    self.apply(event: event, sessionID: id)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      generation == self.operationGeneration,
                      self.selectedSessionID == id else { return }
                self.isLoading = false
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    private func applySessionFrame(_ frame: ChatSessionEventFrame) {
        _ = reconciler.apply(sessionID: frame.sessionID, event: frame.event)
        switch frame.event {
        case .sessionRemoved:
            if selectedSessionID == frame.sessionID {
                selectedSessionID = sessions.first(where: { $0.id != frame.sessionID })?.id
                if let selectedSessionID { beginTranscript(id: selectedSessionID) }
            }
        case .descriptorChanged:
            break
        default:
            break
        }
        publishSessions()
    }

    private func apply(event: ChatSessionEvent, sessionID: String) {
        switch event {
        case .appended(let incoming), .updated(let incoming):
            for message in incoming { messageByID[message.id] = message }
            messages = messageByID.values.sorted { lhs, rhs in
                lhs.seq == rhs.seq ? lhs.id < rhs.id : lhs.seq < rhs.seq
            }
            if incoming.contains(where: { message in
                if case .prose = message.kind { return message.role == .agent }
                return false
            }) {
                streamingProse = nil
            }
        case .stateChanged(let state):
            if let descriptor = selectedSessionID.flatMap({ reconciler.descriptor(for: $0) }) {
                _ = reconciler.upsert(descriptor.withState(state))
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
        case .sessionRemoved:
            _ = reconciler.remove(id: sessionID)
            publishSessions()
        case .unknown:
            break
        }
    }

    private func merge(page: ChatHistoryPage, replacing: Bool) {
        if replacing {
            messageByID = [:]
            blockByID = [:]
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

    private func publishSessions() {
        sessions = reconciler.descriptors
        if let selectedSessionID, sessions.contains(where: { $0.id == selectedSessionID }) == false {
            self.selectedSessionID = sessions.first?.id
        }
    }

    private static func message(for error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
