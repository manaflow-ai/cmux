import CmuxConversation
import CryptoKit
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
    /// The active provider turn used to reject stale steer/interrupt commands.
    public private(set) var activeTurnID: ConversationTurnID?
    /// Capabilities advertised by the selected provider session.
    public private(set) var capabilities: ConversationCapabilities?
    /// Last command receipt, including rejected and uncertain outcomes.
    public private(set) var lastReceipt: ConversationReceipt?
    /// Non-destructive inline error for load/command failures.
    public private(set) var errorMessage: String?
    /// Text currently in the composer.
    public var draft = "" {
        didSet {
            if let selectedSessionID { draftBySession[selectedSessionID] = draft }
        }
    }
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
    /// Task storage has its own non-actor-isolated lifetime object so its
    /// deinitializer can cancel suspended streams when the model is released.
    private let lifetime = ConversationModelLifetime()
    private var generation = 0
    /// Token for the currently selected task. This is separate from the
    /// client generation: a late stream from A must stay stale after a quick
    /// A -> B -> A navigation even though the selected id is A again.
    private var selectionGeneration = 0
    private var currentCursor: ConversationCursor = 0
    private var currentProviderGeneration: ConversationGeneration?
    private var snapshotLoading = false
    private var bufferedEvents: [ConversationEvent] = []
    private var draftBySession: [ConversationID: String] = [:]
    private var cursorBySession: [ConversationID: ConversationCursor] = [:]
    private var pendingCreateRequestID: ConversationCommandID?
    /// Fingerprint of the request body associated with the pending id. A
    /// retry of the exact same create request is idempotent; changing its
    /// provider or workspace must receive a fresh id so the host cannot
    /// reject it as a conflicting reuse.
    private var pendingCreateFingerprint: String?
    private var snapshotBufferLimit = 2_000

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
        selectionGeneration &+= 1
        lifetime.streamTask?.cancel()
        lifetime.snapshotTask?.cancel()
        lifetime.commandTasks.values.forEach { $0.cancel() }
        lifetime.commandTasks.removeAll()
        isSubmitting = false
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
            activeTurnID = nil
            capabilities = nil
            draft = ""
            currentCursor = 0
            currentProviderGeneration = nil
            draftBySession.removeAll()
            cursorBySession.removeAll()
            pendingCreateRequestID = nil
            pendingCreateFingerprint = nil
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
                guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
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
        guard let client, !isSubmitting else {
            errorMessage = ConversationL10n.value("conversation.error.reconnect_create", "Reconnect to create a task.")
            return
        }
        let selectedWorkspace = workspace ?? newTaskWorkspace
        guard let selectedWorkspace else {
            errorMessage = ConversationL10n.value("conversation.error.choose_workspace", "Choose a workspace before starting a task.")
            return
        }
        let provider = provider ?? newTaskProvider
        isSubmitting = true
        let requestFingerprint = [provider.rawValue, selectedWorkspace.id, selectedWorkspace.directory].joined(separator: "\u{1f}")
        let requestID: ConversationCommandID
        if pendingCreateFingerprint == requestFingerprint, let pendingCreateRequestID {
            requestID = pendingCreateRequestID
        } else {
            requestID = ConversationCommandID(rawValue: UUID().uuidString)
            pendingCreateRequestID = requestID
            pendingCreateFingerprint = requestFingerprint
        }
        let request = ConversationCreateRequest(
            requestID: requestID,
            provider: provider,
            workspaceID: selectedWorkspace.id,
            directory: selectedWorkspace.directory,
            launchTarget: .local(directory: selectedWorkspace.directory)
        )
        let expectedGeneration = generation
        Task { [weak self] in
            do {
                let session = try await client.createSession(request)
                guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
                self.pendingCreateRequestID = nil
                self.pendingCreateFingerprint = nil
                self.isSubmitting = false
                self.sessions.removeAll { $0.id == session.id }
                self.sessions.append(session)
                self.selectSession(id: session.id)
            } catch {
                guard let self, self.generation == expectedGeneration else { return }
                self.errorMessage = Self.userMessage(for: error)
                self.isSubmitting = false
            }
        }
    }

    /// Selects a task and begins stream-before-snapshot replay.
    public func selectSession(id: ConversationID?) {
        guard selectedSessionID != id else { return }
        if let previousSessionID = selectedSessionID { draftBySession[previousSessionID] = draft }
        selectionGeneration &+= 1
        lifetime.streamTask?.cancel()
        lifetime.snapshotTask?.cancel()
        selectedSessionID = id
        items = []
        requests = []
        queue = []
        isRunning = false
        activeTurnID = nil
        capabilities = nil
        lastReceipt = nil
        errorMessage = nil
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
    }

    /// Starts a turn. A failed or uncertain receipt leaves the draft intact.
    public func submitDraft() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard let selectedSessionID else { return }
        guard connectionState == .connected else {
            errorMessage = ConversationL10n.value("conversation.error.reconnect_send", "Reconnect to send a message.")
            return
        }
        guard !isSubmitting else { return }
        if isRunning {
            if supportsQueueing { queueTurn(value) }
            else if supportsSteering { steer(value) }
            else { errorMessage = ConversationL10n.value("conversation.error.followup_unsupported", "This provider cannot accept a follow-up while it is working.") }
            return
        }
        send(.startTurn(text: value, model: nil, effort: nil), draftToClear: value, sessionID: selectedSessionID)
    }

    /// Queues a message behind the active turn.
    public func queueTurn(_ text: String? = nil) {
        guard let selectedSessionID else { return }
        let value = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, connectionState == .connected, !isSubmitting, supportsQueueing else { return }
        send(.queue(text: value), draftToClear: value, sessionID: selectedSessionID)
    }

    /// Steers the active turn with a follow-up instruction.
    public func steer(_ text: String? = nil) {
        guard let selectedSessionID else { return }
        let value = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, connectionState == .connected, !isSubmitting, supportsSteering else { return }
        send(.steer(text: value), draftToClear: value, sessionID: selectedSessionID)
    }

    /// Requests a stop; tool lifecycle remains visible until its own event.
    public func stop() {
        guard let selectedSessionID, connectionState == .connected, !isSubmitting, supportsStopping else { return }
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

    /// Downloads one journaled artifact through the optional bounded transfer
    /// protocol. The result is written to a private temporary URL and verified
    /// against the host-provided SHA-256 before it is returned to the caller.
    public func downloadArtifact(_ artifact: ConversationArtifact) async throws -> URL {
        guard let client = client as? any ConversationArtifactClient,
              let selectedSessionID else { throw ConversationArtifactError.unavailable }
        let maximumBytes: UInt64 = 16 * 1024 * 1024
        let maximumChunk = 64 * 1024
        var offset: UInt64 = 0
        var totalBytes: UInt64?
        var pinnedSHA256: String?
        var bytes = Data()
        while totalBytes == nil || offset < (totalBytes ?? 0) {
            let chunk = try await client.artifactChunk(
                ConversationArtifactQuery(
                    sessionID: selectedSessionID,
                    artifactID: artifact.artifactID,
                    offset: offset,
                    expectedSHA256: pinnedSHA256 ?? artifact.sha256
                )
            )
            guard chunk.artifactID == artifact.artifactID,
                  chunk.offset == offset,
                  chunk.data.count <= maximumChunk,
                  chunk.totalBytes <= maximumBytes else { throw ConversationArtifactError.invalidChunk }
            if totalBytes == nil { totalBytes = chunk.totalBytes }
            if pinnedSHA256 == nil { pinnedSHA256 = chunk.sha256 }
            guard chunk.totalBytes == totalBytes,
                  chunk.sha256.caseInsensitiveCompare(pinnedSHA256 ?? "") == .orderedSame,
                  !chunk.data.isEmpty || offset == chunk.totalBytes else {
                throw ConversationArtifactError.invalidChunk
            }
            bytes.append(chunk.data)
            offset += UInt64(chunk.data.count)
            guard offset <= maximumBytes else { throw ConversationArtifactError.tooLarge }
            if chunk.data.isEmpty { throw ConversationArtifactError.invalidChunk }
        }
        guard offset == totalBytes else { throw ConversationArtifactError.invalidChunk }
        let expectedHash = pinnedSHA256 ?? artifact.sha256 ?? ""
        let actualHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard !expectedHash.isEmpty, expectedHash.caseInsensitiveCompare(actualHash) == .orderedSame else {
            throw ConversationArtifactError.hashMismatch
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-conversation-artifacts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = URL(fileURLWithPath: artifact.fileName).lastPathComponent
        let safeFileName = fileName.isEmpty || fileName == "." ? "artifact" : fileName
        let url = directory.appendingPathComponent(safeFileName)
        try bytes.write(to: url, options: .atomic)
        return url
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

    /// Whether the provider can steer its current turn.
    ///
    /// Provider adapters advertise wire operations using their namespaced
    /// operation identifiers. Keep the UI capability check on that canonical
    /// name instead of accepting a fixture-only shorthand.
    public var supportsSteering: Bool { capabilities?.features.contains("turn/steer") == true }

    /// Whether the provider can interrupt/stop its current turn.
    public var supportsStopping: Bool {
        guard let features = capabilities?.features else { return false }
        return features.contains("turn/interrupt")
    }

    /// Whether the provider accepts queued follow-up turns.
    public var supportsQueueing: Bool { capabilities?.features.contains("queue") == true }

    /// Whether the host can provide a workspace file/diff projection.
    /// Codex and OpenCode call this `diff`; the UI intentionally does not
    /// invent a provider-specific `files` capability name.
    public var supportsFiles: Bool {
        guard let features = capabilities?.features else { return false }
        return features.contains("diff") || features.contains("artifact")
    }

    /// Whether the host accepts model/effort/speed configuration commands.
    public var supportsSettings: Bool { capabilities?.features.contains("configure") == true }

    /// Changes provider settings for future turns when advertised by the host.
    public func configure(model: String?, effort: String?, speed: String?) {
        guard let selectedSessionID, connectionState == .connected else { return }
        send(.configure(model: model, effort: effort, speed: speed), draftToClear: nil, sessionID: selectedSessionID)
    }

    private func openSession(id: ConversationID) {
        guard let client else {
            connectionState = .disconnected
            return
        }
        let expectedGeneration = generation
        let expectedSelectionGeneration = selectionGeneration
        connectionState = .connecting
        snapshotLoading = true
        bufferedEvents.removeAll()
        let cursor = currentCursor
        // events() is awaited before snapshot() is started, guaranteeing the
        // host registers its live stream before we request the projection.
        lifetime.streamTask = Task { [weak self] in
            let stream = await client.events(sessionID: id, after: cursor)
            guard !Task.isCancelled,
                  self?.generation == expectedGeneration,
                  self?.selectionGeneration == expectedSelectionGeneration,
                  self?.selectedSessionID == id else { return }
            self?.beginSnapshot(
                client: client,
                id: id,
                cursor: cursor,
                expectedGeneration: expectedGeneration,
                expectedSelectionGeneration: expectedSelectionGeneration
            )
            do {
                for try await event in stream {
                    // Keep the model weak across the stream's suspension points. A discarded
                    // task screen must be reclaimable even when its transport remains connected.
                    guard !Task.isCancelled,
                          let self,
                          self.generation == expectedGeneration,
                          self.selectionGeneration == expectedSelectionGeneration,
                          self.selectedSessionID == id else { return }
                    self.receive(event)
                }
                guard !Task.isCancelled,
                      let self,
                      self.generation == expectedGeneration,
                      self.selectionGeneration == expectedSelectionGeneration,
                      self.selectedSessionID == id else { return }
                self.connectionState = .disconnected
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.generation == expectedGeneration,
                      self.selectionGeneration == expectedSelectionGeneration,
                      self.selectedSessionID == id else { return }
                self.connectionState = .failed(message: Self.userMessage(for: error))
                self.errorMessage = Self.userMessage(for: error)
                self.recoverSnapshotAfterStreamFailure(
                    client: client,
                    id: id,
                    expectedGeneration: expectedGeneration,
                    expectedSelectionGeneration: expectedSelectionGeneration
                )
            }
        }
    }

    /// Replaces a possibly incomplete projection after the host reports a
    /// stream gap or overflow. The model remains disconnected until a later
    /// client replacement registers a fresh live stream.
    private func recoverSnapshotAfterStreamFailure(
        client: any ConversationClient,
        id: ConversationID,
        expectedGeneration: Int,
        expectedSelectionGeneration: Int
    ) {
        lifetime.snapshotTask?.cancel()
        lifetime.snapshotTask = Task { [weak self] in
            do {
                let snapshot = try await client.snapshot(sessionID: id)
                guard !Task.isCancelled,
                      let self,
                      self.generation == expectedGeneration,
                      self.selectionGeneration == expectedSelectionGeneration,
                      self.selectedSessionID == id else { return }
                self.apply(snapshot: snapshot)
                self.connectionState = .disconnected
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.generation == expectedGeneration,
                      self.selectionGeneration == expectedSelectionGeneration,
                      self.selectedSessionID == id else { return }
                self.errorMessage = Self.userMessage(for: error)
            }
        }
    }

    private func beginSnapshot(
        client: any ConversationClient,
        id: ConversationID,
        cursor: ConversationCursor,
        expectedGeneration: Int,
        expectedSelectionGeneration: Int
    ) {
        lifetime.snapshotTask?.cancel()
        lifetime.snapshotTask = Task { [weak self] in
            do {
                let snapshot = try await client.snapshot(sessionID: id)
                guard !Task.isCancelled,
                      let self,
                      self.generation == expectedGeneration,
                      self.selectionGeneration == expectedSelectionGeneration,
                      self.selectedSessionID == id else { return }
                self.apply(snapshot: snapshot)
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.generation == expectedGeneration,
                      self.selectionGeneration == expectedSelectionGeneration,
                      self.selectedSessionID == id else { return }
                self.snapshotLoading = false
                self.connectionState = .failed(message: Self.userMessage(for: error))
                self.errorMessage = Self.userMessage(for: error)
            }
        }
    }

    private func receive(_ event: ConversationEvent) {
        guard event.sessionID == selectedSessionID else { return }
        if snapshotLoading {
            guard bufferedEvents.count < snapshotBufferLimit else {
                snapshotLoading = false
                bufferedEvents.removeAll()
                connectionState = .failed(message: ConversationL10n.value("conversation.error.event_overflow", "The event stream changed too quickly. Reopen the task to continue."))
                errorMessage = connectionStateMessage
                return
            }
            bufferedEvents.append(event)
            return
        }
        apply(event: event)
    }

    private func apply(snapshot: ConversationSnapshot) {
        guard snapshot.session.id == selectedSessionID else { return }
        guard snapshot.cursor >= currentCursor else { return }
        // A host can close its event stream while its durable snapshot is
        // still in flight.  Preserve that terminal connection state when the
        // projection arrives; otherwise applying the snapshot would briefly
        // (and incorrectly) make a retained, disconnected task writable.
        let streamAlreadyEnded = connectionState == .disconnected
        items = snapshot.items
        requests = snapshot.pendingRequests
        queue = snapshot.queued
        currentCursor = snapshot.cursor
        currentProviderGeneration = snapshot.generation
        activeTurnID = snapshot.activeTurnID
        isRunning = snapshot.isTurnRunning
        capabilities = snapshot.capabilities
        cursorBySession[snapshot.session.id] = currentCursor
        lastReceipt = snapshot.receipts.last
        snapshotLoading = false
        if !streamAlreadyEnded { connectionState = .connected }
        errorMessage = nil
        let replay = bufferedEvents.sorted { $0.sequence < $1.sequence }
        bufferedEvents.removeAll()
        replay.forEach { apply(event: $0) }
    }

    func apply(event: ConversationEvent) {
        guard event.sessionID == selectedSessionID else { return }
        guard event.sequence > currentCursor else { return }
        if event.generation != currentProviderGeneration {
            // A restart event establishes the new generation. Other events from
            // an old provider connection must not mutate the replacement task.
            guard currentProviderGeneration == nil || event.kind == .restarted else { return }
            if currentProviderGeneration != nil { requests.removeAll() }
            currentProviderGeneration = event.generation
        }
        currentCursor = event.sequence
        if let selectedSessionID { cursorBySession[selectedSessionID] = event.sequence }
        switch event.kind {
        case .item:
            if let item = event.item {
                let previous = items.first(where: { $0.id == item.id })
                let reduced = item.applying(to: previous, mode: event.itemUpdate)
                if let index = items.firstIndex(where: { $0.id == reduced.id }) { items[index] = reduced } else { items.append(reduced) }
            }
        case .request:
            if let request = event.request {
                if let index = requests.firstIndex(where: { $0.id == request.id }) { requests[index] = request } else { requests.append(request) }
            }
        case .queue:
            if let queue = event.queue { self.queue = queue }
        case .run, .turn:
            // A provider can finish an earlier turn after a newer turn has
            // already started (especially while reconnecting). Keep the
            // current run alive until a lifecycle event for that turn arrives.
            let isForDifferentActiveTurn = activeTurnID != nil
                && event.turnID != nil
                && activeTurnID != event.turnID
            guard !isForDifferentActiveTurn else { break }
            activeTurnID = event.turnID ?? activeTurnID
            if let state = event.state {
                isRunning = ["running", "starting", "working", "thinking"].contains(state.lowercased())
                if !isRunning { activeTurnID = nil }
            }
        case .receipt:
            if let receipt = event.receipt { apply(receipt: receipt) }
        case .restarted:
            requests.removeAll()
            errorMessage = ConversationL10n.value("conversation.error.provider_restarted", "The provider restarted. Pending requests were cleared.")
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
            expectedTurnID: activeTurnID,
            command: command
        )
        let task = Task { [weak self] in
            do {
                let receipt = try await client.execute(envelope)
                guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
                let isApplied = receipt.state == .applied
                let isRejectedOrUncertain = receipt.state == .rejected || receipt.state == .uncertain
                if self.selectedSessionID == sessionID {
                    self.apply(receipt: receipt)
                    if isRejectedOrUncertain,
                       let draftToClear, self.draft.isEmpty { self.updateDraft(draftToClear) }
                    if isApplied,
                       let restored = receipt.draftText ?? restoreDraft,
                       !restored.isEmpty,
                       self.draft.isEmpty {
                        self.updateDraft(restored)
                    }
                } else if isRejectedOrUncertain {
                    if let draftToClear, self.draftBySession[sessionID]?.isEmpty != false {
                        self.draftBySession[sessionID] = draftToClear
                    }
                } else if isApplied,
                          let restored = receipt.draftText ?? restoreDraft,
                          !restored.isEmpty,
                          self.draftBySession[sessionID]?.isEmpty != false {
                    self.draftBySession[sessionID] = restored
                }
            } catch {
                guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
                if self.selectedSessionID == sessionID {
                    if let draftToClear, self.draft.isEmpty { self.updateDraft(draftToClear) }
                    self.errorMessage = Self.userMessage(for: error)
                } else if let draftToClear, self.draftBySession[sessionID]?.isEmpty != false {
                    self.draftBySession[sessionID] = draftToClear
                }
            }
            if !Task.isCancelled, let self, self.generation == expectedGeneration {
                self.isSubmitting = false
                self.lifetime.commandTasks.removeValue(forKey: commandID.rawValue)
            }
        }
        lifetime.commandTasks[commandID.rawValue] = task
    }

    private func sendGlobal(_ command: ConversationCommand, sessionID: ConversationID) {
        guard let client, connectionState == .connected, !isSubmitting else { return }
        isSubmitting = true
        let commandID = ConversationCommandID(rawValue: UUID().uuidString)
        let expectedGeneration = generation
        let expectedProviderGeneration = sessions.first(where: { $0.id == sessionID })?.generation ?? currentProviderGeneration
        let envelope = ConversationCommandEnvelope(commandID: commandID, sessionID: sessionID, expectedGeneration: expectedProviderGeneration, command: command)
        let task = Task { [weak self] in
            do {
                let receipt = try await client.execute(envelope)
                guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
                let isApplied = receipt.state == .applied
                if self.selectedSessionID == sessionID {
                    self.apply(receipt: receipt)
                }
                if !isApplied {
                    if self.selectedSessionID == sessionID,
                       receipt.state == .rejected || receipt.state == .uncertain {
                        self.errorMessage = receipt.reason ?? ConversationL10n.value("conversation.error.command_rejected", "The command was rejected.")
                    }
                } else {
                    switch command {
                    case .rename(let title):
                        if let index = self.sessions.firstIndex(where: { $0.id == sessionID }) { self.sessions[index].title = title }
                    case .setPinned(let pinned):
                        if let index = self.sessions.firstIndex(where: { $0.id == sessionID }) { self.sessions[index].isPinned = pinned }
                    case .setArchived(true):
                        self.sessions.removeAll { $0.id == sessionID }
                        if self.selectedSessionID == sessionID { self.selectSession(id: nil) }
                    default:
                        break
                    }
                    self.refreshSessions()
                }
            } catch {
                if !Task.isCancelled, let self, self.generation == expectedGeneration, self.selectedSessionID == sessionID {
                    self.errorMessage = Self.userMessage(for: error)
                }
            }
            if !Task.isCancelled, let self, self.generation == expectedGeneration {
                self.isSubmitting = false
                self.lifetime.commandTasks.removeValue(forKey: commandID.rawValue)
            }
        }
        lifetime.commandTasks[commandID.rawValue] = task
    }

    private func apply(receipt: ConversationReceipt) {
        lastReceipt = receipt
        if receipt.state == .rejected { errorMessage = receipt.reason ?? ConversationL10n.value("conversation.error.command_rejected", "The command was rejected.") }
        if receipt.state == .uncertain { errorMessage = receipt.reason ?? ConversationL10n.value("conversation.error.command_uncertain", "The command outcome is unknown. Check the task before retrying.") }
    }

    private static func userMessage(for error: any Error) -> String {
        if let error = error as? any LocalizedError, let message = error.errorDescription { return message }
        return ConversationL10n.value("conversation.error.unavailable", "The task connection is unavailable.")
    }

    private var connectionStateMessage: String {
        if case .failed(let message) = connectionState { return message }
        return ConversationL10n.value("conversation.error.event_overflow", "The event stream changed too quickly. Reopen the task to continue.")
    }
}

/// Owns model tasks outside the main-actor-isolated model. `deinit` is
/// nonisolated, so this is the place where suspended streams are cancelled
/// when a discarded conversation screen releases its model.
private final class ConversationModelLifetime {
    var streamTask: Task<Void, Never>?
    var snapshotTask: Task<Void, Never>?
    var commandTasks: [String: Task<Void, Never>] = [:]

    deinit {
        streamTask?.cancel()
        snapshotTask?.cancel()
        commandTasks.values.forEach { $0.cancel() }
    }
}

/// Errors for bounded artifact previews.
public enum ConversationArtifactError: LocalizedError, Sendable {
    case unavailable
    case invalidChunk
    case tooLarge
    case hashMismatch

    public var errorDescription: String? {
        switch self {
        case .unavailable: ConversationL10n.value("conversation.error.artifact_unavailable", "This artifact is unavailable from the connected host.")
        case .invalidChunk: ConversationL10n.value("conversation.error.artifact_chunk", "The artifact transfer returned an invalid chunk.")
        case .tooLarge: ConversationL10n.value("conversation.error.artifact_large", "This artifact is larger than the supported transfer limit.")
        case .hashMismatch: ConversationL10n.value("conversation.error.artifact_hash", "The downloaded artifact failed its integrity check.")
        }
    }
}
