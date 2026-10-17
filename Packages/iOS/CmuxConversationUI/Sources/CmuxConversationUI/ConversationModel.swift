import CmuxConversation
import Foundation
import Observation

/// Main-actor state for the native conversation surface. The model owns stream
/// lifetime, replay cursors, drafts and command receipts; views only render it
/// and invoke the intent methods below.
@MainActor
@Observable
public final class ConversationModel {
    /// Sessions in the current host scope.
    public private(set) var sessions: [ConversationSession] = []
    /// The selected task, if the task list has an active selection.
    public private(set) var selectedSessionID: ConversationID?
    /// The selected task's durable transcript.
    public private(set) var items: [ConversationItem] = []
    /// Requests waiting on the user.
    public private(set) var requests: [ConversationRequest] = []
    /// Turns queued behind the active run.
    public private(set) var queue: [ConversationQueueItem] = []
    /// Current stream status.
    public private(set) var connectionState: ConversationConnectionState = .disconnected
    /// Whether the selected task's run is active.
    public private(set) var isRunning = false
    /// Last command receipt, including rejected and uncertain outcomes.
    public private(set) var lastReceipt: ConversationReceipt?
    /// Non-destructive inline error for load/command failures.
    public private(set) var errorMessage: String?
    /// Text currently in the composer.
    public var draft = ""
    /// Filter text for the task list.
    public var searchText = ""
    /// A provider/workspace used by the new-task sheet.
    public var newTaskProvider: ConversationProvider = .codex
    public var newTaskWorkspace: ConversationWorkspaceChoice?
    /// Workspaces supplied by the shell bridge for the new-task sheet.
    public var workspaces: [ConversationWorkspaceChoice]
    /// Whether a command is in flight, used to prevent double submits.
    public private(set) var isSubmitting = false

    private var client: (any ConversationClient)?
    private(set) var scopeID: String
    private var streamTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var commandTasks: [String: Task<Void, Never>] = [:]
    private var generation = 0
    private var currentCursor: ConversationCursor = 0
    private var currentProviderGeneration: ConversationGeneration?
    private var snapshotLoading = false
    private var bufferedEvents: [ConversationEvent] = []
    private var draftBySession: [ConversationID: String] = [:]
    private var cursorBySession: [ConversationID: ConversationCursor] = [:]

    /// Creates state for a host scope. A nil client starts in a disconnected,
    /// read-only state and can be replaced when pairing becomes available.
    public init(
        client: (any ConversationClient)? = nil,
        scopeID: String = "",
        workspaces: [ConversationWorkspaceChoice] = []
    ) {
        self.client = client
        self.scopeID = scopeID
        self.workspaces = workspaces
        connectionState = client == nil ? .disconnected : .connecting
    }

    /// Replaces the transport when pairing or the selected host changes.
    /// Replacing within the same scope preserves task selection and drafts;
    /// crossing scopes clears selection and transcript before any new snapshot.
    public func replaceClient(_ client: (any ConversationClient)?, scopeID: String) {
        let scopeChanged = self.scopeID != scopeID
        generation &+= 1
        streamTask?.cancel()
        snapshotTask?.cancel()
        commandTasks.values.forEach { $0.cancel() }
        commandTasks.removeAll()
        self.client = client
        self.scopeID = scopeID
        connectionState = client == nil ? .disconnected : .connecting
        errorMessage = nil
        lastReceipt = nil
        if scopeChanged {
            selectedSessionID = nil
            items = []
            requests = []
            queue = []
            isRunning = false
            draft = ""
            currentCursor = 0
            currentProviderGeneration = nil
            draftBySession.removeAll()
            cursorBySession.removeAll()
        }
        guard client != nil else {
            if scopeChanged { sessions = [] }
            return
        }
        refreshSessions()
        if let selectedSessionID { openSession(id: selectedSessionID) }
    }

    /// Refreshes the task list from the current host.
    public func refreshSessions() {
        guard let client else {
            connectionState = .disconnected
            return
        }
        let expectedGeneration = generation
        Task { [weak self] in
            do {
                let sessions = try await client.listSessions()
                guard let self, self.generation == expectedGeneration else { return }
                self.sessions = sessions.filter { !$0.isArchived }.sorted { lhs, rhs in
                    if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
                    return lhs.updatedAt > rhs.updatedAt
                }
                self.connectionState = .connected
                self.errorMessage = nil
            } catch {
                guard let self, self.generation == expectedGeneration else { return }
                self.connectionState = .failed(message: Self.userMessage(for: error))
                self.errorMessage = Self.userMessage(for: error)
            }
        }
    }

    /// Creates a new task and opens it in the conversation view.
    public func createSession(provider: ConversationProvider? = nil, workspace: ConversationWorkspaceChoice? = nil) {
        guard let client else {
            errorMessage = "Reconnect to create a task."
            return
        }
        let selectedWorkspace = workspace ?? newTaskWorkspace
        guard let selectedWorkspace else {
            errorMessage = "Choose a workspace before starting a task."
            return
        }
        let provider = provider ?? newTaskProvider
        let request = ConversationCreateRequest(
            requestID: ConversationCommandID(rawValue: UUID().uuidString),
            provider: provider,
            workspaceID: selectedWorkspace.id,
            directory: selectedWorkspace.directory,
            launchTarget: .local(directory: selectedWorkspace.directory)
        )
        let expectedGeneration = generation
        Task { [weak self] in
            do {
                let session = try await client.createSession(request)
                guard let self, self.generation == expectedGeneration else { return }
                self.sessions.removeAll { $0.id == session.id }
                self.sessions.append(session)
                self.selectSession(id: session.id)
            } catch {
                guard let self, self.generation == expectedGeneration else { return }
                self.errorMessage = Self.userMessage(for: error)
            }
        }
    }

    /// Selects a task and begins stream-before-snapshot replay.
    public func selectSession(id: ConversationID?) {
        guard selectedSessionID != id else { return }
        streamTask?.cancel()
        snapshotTask?.cancel()
        selectedSessionID = id
        items = []
        requests = []
        queue = []
        isRunning = false
        currentCursor = id.flatMap { cursorBySession[$0] } ?? 0
        draft = id.flatMap { draftBySession[$0] } ?? ""
        bufferedEvents.removeAll()
        snapshotLoading = false
        guard let id else { return }
        openSession(id: id)
    }

    /// Updates the draft without submitting it.
    public func updateDraft(_ value: String) {
        draft = value
        if let selectedSessionID { draftBySession[selectedSessionID] = value }
    }

    /// Starts a turn. A failed or uncertain receipt leaves the draft intact.
    public func submitDraft() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard let selectedSessionID else { return }
        guard connectionState == .connected else {
            errorMessage = "Reconnect to send a message."
            return
        }
        guard !isSubmitting else { return }
        if isRunning {
            queueTurn(value)
            return
        }
        send(.startTurn(text: value, model: nil, effort: nil), draftToClear: value, sessionID: selectedSessionID)
    }

    /// Queues a message behind the active turn.
    public func queueTurn(_ text: String? = nil) {
        guard let selectedSessionID else { return }
        let value = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, connectionState == .connected, !isSubmitting else { return }
        send(.queue(text: value), draftToClear: value, sessionID: selectedSessionID)
    }

    /// Steers the active turn with a follow-up instruction.
    public func steer(_ text: String? = nil) {
        guard let selectedSessionID else { return }
        let value = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, connectionState == .connected, !isSubmitting else { return }
        send(.steer(text: value), draftToClear: value, sessionID: selectedSessionID)
    }

    /// Requests a stop; tool lifecycle remains visible until its own event.
    public func stop() {
        guard let selectedSessionID, connectionState == .connected, !isSubmitting else { return }
        send(.interrupt, draftToClear: nil, sessionID: selectedSessionID)
    }

    /// Resolves an approval request.
    public func resolveApproval(_ request: ConversationRequest, decision: ConversationApprovalDecision) {
        guard let selectedSessionID, connectionState == .connected else { return }
        send(.resolveApproval(requestID: request.id, decision: decision), draftToClear: nil, sessionID: selectedSessionID)
    }

    /// Answers a question with one or more indexed answers.
    public func answer(request: ConversationRequest, answers: [ConversationQuestionAnswer]) {
        guard let selectedSessionID, connectionState == .connected, !answers.isEmpty else { return }
        send(.answerQuestion(requestID: request.id, answers: answers), draftToClear: nil, sessionID: selectedSessionID)
    }

    /// Answers one simple question with a text value.
    public func answer(request: ConversationRequest, value: String) {
        answer(request: request, answers: [ConversationQuestionAnswer(index: request.question?.index ?? 0, text: value)])
    }

    /// Edits a queued turn.
    public func editQueue(_ item: ConversationQueueItem, text: String) {
        guard let selectedSessionID, connectionState == .connected else { return }
        send(.editQueued(itemID: item.id, text: text), draftToClear: nil, sessionID: selectedSessionID)
    }

    /// Cancels a queued turn. The model restores its text to the composer.
    public func cancelQueue(_ item: ConversationQueueItem) {
        guard let selectedSessionID, connectionState == .connected else { return }
        send(.cancelQueued(itemID: item.id), draftToClear: nil, sessionID: selectedSessionID, restoreDraft: item.text)
    }

    /// Renames a task from its context menu.
    public func renameSession(_ session: ConversationSession, title: String) {
        sendGlobal(.rename(title: title), sessionID: session.id)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index].title = title }
    }

    /// Pins or unpins a task.
    public func setPinned(_ session: ConversationSession, pinned: Bool) {
        sendGlobal(.setPinned(pinned), sessionID: session.id)
    }

    /// Archives a task.
    public func archive(_ session: ConversationSession) {
        sendGlobal(.setArchived(true), sessionID: session.id)
    }

    /// Sessions filtered by search text, retaining pinned grouping in the view.
    public var filteredSessions: [ConversationSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.directory.localizedCaseInsensitiveContains(query)
                || $0.provider.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    /// Whether a blocking request currently replaces the composer.
    public var blockingRequest: ConversationRequest? {
        requests.first(where: \ .isBlocking)
    }

    /// Whether the selected task has an asynchronous question card.
    public var asynchronousRequest: ConversationRequest? {
        requests.first(where: { $0.state == .pending && !$0.isBlocking })
    }

    private func openSession(id: ConversationID) {
        guard let client else {
            connectionState = .disconnected
            return
        }
        let expectedGeneration = generation
        connectionState = .connecting
        snapshotLoading = true
        bufferedEvents.removeAll()
        let cursor = currentCursor
        // events() is awaited before snapshot() is started, guaranteeing the
        // host registers its live stream before we request the projection.
        streamTask = Task { [weak self] in
            let stream = await client.events(sessionID: id, after: cursor)
            guard let self, self.generation == expectedGeneration, self.selectedSessionID == id else { return }
            self.beginSnapshot(client: client, id: id, cursor: cursor, expectedGeneration: expectedGeneration)
            do {
                for try await event in stream {
                    guard self.generation == expectedGeneration, self.selectedSessionID == id else { return }
                    self.receive(event)
                }
                guard self.generation == expectedGeneration, self.selectedSessionID == id else { return }
                self.connectionState = .disconnected
            } catch {
                guard self.generation == expectedGeneration, self.selectedSessionID == id else { return }
                self.connectionState = .failed(message: Self.userMessage(for: error))
                self.errorMessage = Self.userMessage(for: error)
            }
        }
    }

    private func beginSnapshot(client: any ConversationClient, id: ConversationID, cursor: ConversationCursor, expectedGeneration: Int) {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            do {
                let snapshot = try await client.snapshot(sessionID: id)
                guard let self, self.generation == expectedGeneration, self.selectedSessionID == id else { return }
                self.apply(snapshot: snapshot)
            } catch {
                guard let self, self.generation == expectedGeneration, self.selectedSessionID == id else { return }
                self.snapshotLoading = false
                self.connectionState = .failed(message: Self.userMessage(for: error))
                self.errorMessage = Self.userMessage(for: error)
            }
        }
    }

    private func receive(_ event: ConversationEvent) {
        guard event.sessionID == selectedSessionID else { return }
        if snapshotLoading {
            bufferedEvents.append(event)
            return
        }
        apply(event: event)
    }

    private func apply(snapshot: ConversationSnapshot) {
        guard snapshot.session.id == selectedSessionID else { return }
        guard snapshot.cursor >= currentCursor else { return }
        items = snapshot.items
        requests = snapshot.pendingRequests
        queue = snapshot.queued
        currentCursor = snapshot.cursor
        currentProviderGeneration = snapshot.generation
        cursorBySession[snapshot.session.id] = currentCursor
        isRunning = snapshot.session.state == .starting || snapshot.session.state == .ready && snapshot.items.last?.kind == .tool
        lastReceipt = snapshot.receipts.last
        snapshotLoading = false
        connectionState = .connected
        errorMessage = nil
        let replay = bufferedEvents.sorted { $0.sequence < $1.sequence }
        bufferedEvents.removeAll()
        replay.forEach { apply(event: $0) }
    }

    private func apply(event: ConversationEvent) {
        guard event.sessionID == selectedSessionID else { return }
        if event.generation != currentProviderGeneration {
            // A restarted provider invalidates old requests and cursors.
            if currentProviderGeneration != nil { requests.removeAll() }
            currentProviderGeneration = event.generation
        }
        guard event.sequence > currentCursor else { return }
        currentCursor = event.sequence
        if let selectedSessionID { cursorBySession[selectedSessionID] = event.sequence }
        switch event.kind {
        case .item:
            if let item = event.item {
                if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item } else { items.append(item) }
                items.sort { $0.sequence < $1.sequence }
            }
        case .request:
            if let request = event.request {
                if let index = requests.firstIndex(where: { $0.id == request.id }) { requests[index] = request } else { requests.append(request) }
            }
        case .queue:
            if let queue = event.queue { self.queue = queue }
        case .run, .turn:
            if let state = event.state { isRunning = ["running", "starting", "working", "thinking"].contains(state.lowercased()) }
        case .receipt:
            if let receipt = event.receipt { apply(receipt: receipt) }
        case .restarted:
            requests.removeAll()
            errorMessage = "The provider restarted. Pending requests were cleared."
        case .unknown:
            break
        }
    }

    private func send(
        _ command: ConversationCommand,
        draftToClear: String?,
        sessionID: ConversationID,
        restoreDraft: String? = nil
    ) {
        guard let client, !isSubmitting else { return }
        isSubmitting = true
        let commandID = ConversationCommandID(rawValue: UUID().uuidString)
        if let draftToClear, draft == draftToClear { updateDraft("") }
        let expectedGeneration = generation
        let envelope = ConversationCommandEnvelope(
            commandID: commandID,
            sessionID: sessionID,
            expectedGeneration: currentProviderGeneration,
            command: command
        )
        let task = Task { [weak self] in
            do {
                let receipt = try await client.execute(envelope)
                guard let self, self.generation == expectedGeneration else { return }
                self.apply(receipt: receipt)
                if receipt.state == .rejected || receipt.state == .uncertain,
                   let draftToClear, self.draft.isEmpty { self.updateDraft(draftToClear) }
            } catch {
                guard let self, self.generation == expectedGeneration else { return }
                if let draftToClear, self.draft.isEmpty { self.updateDraft(draftToClear) }
                self.errorMessage = Self.userMessage(for: error)
            }
            if let self, self.generation == expectedGeneration {
                if let restoreDraft, self.draft.isEmpty { self.updateDraft(restoreDraft) }
                self.isSubmitting = false
            }
        }
        commandTasks[commandID.rawValue] = task
    }

    private func sendGlobal(_ command: ConversationCommand, sessionID: ConversationID) {
        guard let client, connectionState == .connected, !isSubmitting else { return }
        isSubmitting = true
        let commandID = ConversationCommandID(rawValue: UUID().uuidString)
        let expectedGeneration = generation
        let envelope = ConversationCommandEnvelope(commandID: commandID, sessionID: sessionID, expectedGeneration: nil, command: command)
        let task = Task { [weak self] in
            do {
                let receipt = try await client.execute(envelope)
                guard let self, self.generation == expectedGeneration else { return }
                self.apply(receipt: receipt)
                if case .setArchived(true) = command {
                    self.sessions.removeAll { $0.id == sessionID }
                    if self.selectedSessionID == sessionID { self.selectSession(id: nil) }
                }
            } catch {
                self?.errorMessage = Self.userMessage(for: error)
            }
            if let self, self.generation == expectedGeneration { self.isSubmitting = false }
        }
        commandTasks[commandID.rawValue] = task
    }

    private func apply(receipt: ConversationReceipt) {
        lastReceipt = receipt
        if receipt.state == .rejected { errorMessage = receipt.reason ?? "The command was rejected." }
        if receipt.state == .uncertain { errorMessage = receipt.reason ?? "The command outcome is unknown. Check the task before retrying." }
    }

    private static func userMessage(for error: any Error) -> String {
        if let error = error as? any LocalizedError, let message = error.errorDescription { return message }
        return "The Cloud service is unavailable."
    }
}
