import Foundation
public import Observation

/// One conversation as a GUI shows it: the folded state, the connection,
/// and the actions a user takes.
///
/// It is backend-agnostic: it talks to any ``ConversationBackend``. Sending
/// is instant: the message appears at once under its client identifier and
/// is kept in the ``OutboxStoring`` until the backend confirms it, so it is
/// sent again (never twice) after a dropped link or an app restart. A tab
/// that has no conversation yet creates one with its first message.
///
/// ```swift
/// let model = ConversationModel(backend: backend, conversationID: nil, settings: inherited, outbox: outbox, outboxKey: tabID)
/// await model.start()
/// model.send(text: "Summarize this PDF", attachments: [pdf])
/// ```
@MainActor
@Observable
public final class ConversationModel {
    /// Everything to show, folded from the conversation's events.
    public private(set) var state = ConversationState()
    /// The conversation, once it exists on the backend.
    public private(set) var conversationID: ConversationID?
    /// Whether the backend is reachable.
    public private(set) var connection: BackendConnectionState = .connecting
    /// An older history page is loading.
    public private(set) var isLoadingOlder = false
    /// Settings used to create the conversation on the first message.
    public var settings: ConversationSettings
    /// Called once when the first message creates the conversation, so the
    /// owner (a tab record) can store the reference.
    public var onConversationCreated: (@MainActor (ConversationID) -> Void)?

    @ObservationIgnored private let backend: any ConversationBackend
    @ObservationIgnored private let outbox: any OutboxStoring
    @ObservationIgnored private let outboxKey: String
    @ObservationIgnored private let pageSize: Int
    @ObservationIgnored private let reducer = ConversationReducer()
    @ObservationIgnored private var feed: (any ConversationFeed)?
    @ObservationIgnored private var feedTask: Task<Void, Never>?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var creating: Task<ConversationID?, Never>?
    @ObservationIgnored private var uploads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var localFiles: [String: OutgoingAttachment] = [:]
    @ObservationIgnored private var savedOutbox: [ClientMessageID] = []
    /// Messages leave in the order they were sent: one consumer delivers them.
    @ObservationIgnored private var outgoing: AsyncStream<OutgoingMessage>.Continuation?
    @ObservationIgnored private var deliveryTask: Task<Void, Never>?

    /// Creates a model.
    /// - Parameters:
    ///   - backend: The backend the conversation lives on.
    ///   - conversationID: The conversation, or `nil` for a new tab that
    ///     creates one on its first message.
    ///   - settings: Settings for creating the conversation.
    ///   - outbox: Where unconfirmed messages are kept.
    ///   - outboxKey: This conversation's key in the outbox (a tab id).
    ///   - pageSize: Events loaded per history page; defaults to 400.
    public init(backend: any ConversationBackend, conversationID: ConversationID?, settings: ConversationSettings = .init(), outbox: any OutboxStoring, outboxKey: String, pageSize: Int = 400) {
        self.backend = backend
        self.conversationID = conversationID
        self.settings = settings
        self.outbox = outbox
        self.outboxKey = outboxKey
        self.pageSize = pageSize
    }

    /// Restores unconfirmed messages, follows the connection and opens the
    /// conversation's feed.
    public func start() async {
        for message in await outbox.load(key: outboxKey) {
            reducer.applyLocalSend(message, to: &state)
            for a in message.attachments {
                localFiles[a.uploadID] = a
            }
        }
        savedOutbox = reducer.unconfirmedSends(in: state).map(\.clientMessageID)
        let states = backend.connectionStates()
        connectionTask = Task { [weak self] in
            for await s in states {
                guard let self else { return }
                self.connection = s
                if case .connected = s {
                    await self.connected()
                }
            }
        }
    }

    /// Closes the feed and stops following the connection.
    public func stop() async {
        connectionTask?.cancel()
        outgoing?.finish()
        outgoing = nil
        deliveryTask?.cancel()
        feedTask?.cancel()
        for t in uploads.values {
            t.cancel()
        }
        uploads.removeAll()
        await feed?.close()
        feed = nil
    }

    private func connected() async {
        if feed == nil, let id = conversationID {
            await openFeed(id)
        }
        await deliverUnconfirmed()
    }

    private func openFeed(_ id: ConversationID) async {
        guard feed == nil else { return }
        guard let f = try? await backend.open(id, pageSize: pageSize) else { return }
        feed = f
        let updates = f.updates
        feedTask = Task { [weak self] in
            for await u in updates {
                guard let self else { return }
                switch u {
                case let .events(envelopes, hasOlder):
                    self.reducer.apply(envelopes, to: &self.state)
                    if let hasOlder {
                        self.reducer.setHasOlder(hasOlder, in: &self.state)
                    }
                    await self.persistOutboxIfChanged()
                case let .metadata(m):
                    self.reducer.applyMetadata(m, to: &self.state)
                case .reconnected:
                    await self.deliverUnconfirmed()
                }
            }
        }
    }

    // MARK: - Actions

    /// Sends a message. It shows at once; files upload in the background.
    /// - Parameters:
    ///   - text: The message text.
    ///   - attachments: Files on this device to attach.
    ///   - steer: Steer the running turn instead of queueing, when supported.
    /// - Returns: The message's client identifier.
    @discardableResult
    public func send(text: String, attachments: [OutgoingAttachment] = [], steer: Bool = false) -> ClientMessageID {
        let message = OutgoingMessage(text: text, attachments: attachments, steer: steer)
        reducer.applyLocalSend(message, to: &state)
        for a in attachments {
            localFiles[a.uploadID] = a
        }
        Task { await persistOutboxIfChanged() }
        enqueueDelivery(message)
        return message.clientMessageID
    }

    /// Removes a waiting message from the queue.
    /// - Parameter id: The message's client identifier.
    /// - Throws: When the backend refuses or is unreachable.
    public func dequeue(_ id: ClientMessageID) async throws {
        guard let conversationID else { return }
        try await backend.perform(.dequeue(id), on: conversationID)
    }

    /// Sends again a message whose files never arrived; uploads resume.
    /// - Parameter id: The message's client identifier.
    /// - Throws: When the backend refuses (for example files went missing).
    public func retry(_ id: ClientMessageID) async throws {
        guard let conversationID else { return }
        if let item = state.items.first(where: { $0.id == ConversationReducer.userID(id) }), case let .message(m) = item.kind {
            for uploadID in m.attachmentIDs {
                if let a = localFiles[uploadID] {
                    startUpload(a, to: conversationID)
                }
            }
        }
        try await backend.perform(.retry(id), on: conversationID)
    }

    /// Answers an approval request.
    /// - Parameters:
    ///   - requestID: The request's identifier.
    ///   - optionID: The chosen option.
    /// - Throws: When the backend refuses or is unreachable.
    public func answer(_ requestID: String, optionID: String) async throws {
        guard let conversationID else { return }
        try await backend.perform(.answerApproval(id: requestID, optionID: optionID), on: conversationID)
    }

    /// Stops the running turn.
    /// - Throws: When the backend is unreachable.
    public func cancelTurn() async throws {
        guard let conversationID else { return }
        try await backend.perform(.cancelTurn, on: conversationID)
    }

    /// Runs any other command on the conversation.
    /// - Parameter command: The command.
    /// - Throws: When the backend refuses or is unreachable.
    public func perform(_ command: ConversationCommand) async throws {
        guard let conversationID else { return }
        try await backend.perform(command, on: conversationID)
    }

    /// Loads the page of history before the oldest loaded event.
    public func loadOlder() async {
        guard let feed, state.hasOlder, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        try? await feed.loadOlder(pageSize: pageSize)
    }

    // MARK: - Delivery

    private func ensureConversation(first message: OutgoingMessage) async -> ConversationID? {
        if let conversationID { return conversationID }
        if let creating { return await creating.value }
        let task = Task<ConversationID?, Never> { [backend, settings] in
            try? await backend.create(settings: settings, firstMessage: message)
        }
        creating = task
        let id = await task.value
        creating = nil
        if let id {
            conversationID = id
            onConversationCreated?(id)
            await openFeed(id)
        }
        return id
    }

    private func deliver(_ message: OutgoingMessage) async {
        guard let id = await ensureConversation(first: message) else {
            reducer.setLocalSendFailed(message.clientMessageID, failed: true, in: &state)
            return
        }
        for a in message.attachments {
            startUpload(a, to: id)
        }
        do {
            try await backend.perform(.send(message), on: id)
            reducer.setLocalSendFailed(message.clientMessageID, failed: false, in: &state)
        } catch {
            reducer.setLocalSendFailed(message.clientMessageID, failed: true, in: &state)
        }
    }

    private func deliverUnconfirmed() async {
        for message in reducer.unconfirmedSends(in: state) {
            reducer.setLocalSendFailed(message.clientMessageID, failed: false, in: &state)
            // A message still in flight is sent again; the backend runs a
            // client message id once.
            enqueueDelivery(message)
        }
    }

    private func enqueueDelivery(_ message: OutgoingMessage) {
        if outgoing == nil {
            // Unbounded: it holds only messages the user typed, in order.
            let (stream, continuation) = AsyncStream<OutgoingMessage>.makeStream()
            outgoing = continuation
            deliveryTask = Task { [weak self] in
                for await m in stream {
                    await self?.deliver(m)
                }
            }
        }
        outgoing?.yield(message)
    }

    private func startUpload(_ attachment: OutgoingAttachment, to id: ConversationID) {
        guard uploads[attachment.uploadID] == nil else { return }
        guard FileManager.default.isReadableFile(atPath: attachment.fileURL.path) else {
            reducer.markLocalAttachmentMissing(uploadID: attachment.uploadID, in: &state)
            return
        }
        uploads[attachment.uploadID] = Task { [weak self, backend] in
            do {
                if let thumbnail = attachment.thumbnail {
                    // A preview failing must not hold the original back.
                    do {
                        for try await _ in backend.upload(UploadFile(thumbnail: thumbnail), to: id) {}
                    } catch {}
                }
                for try await sent in backend.upload(UploadFile(original: attachment), to: id) {
                    guard let self else { return }
                    self.reducer.applyLocalUploadProgress(uploadID: attachment.uploadID, sent: sent, to: &self.state)
                }
            } catch {
                // The backend reports the failure (after its grace period); a
                // reconnect or retry starts the upload again.
            }
            self?.uploads[attachment.uploadID] = nil
        }
    }

    private func persistOutboxIfChanged() async {
        let pending = reducer.unconfirmedSends(in: state)
        let ids = pending.map(\.clientMessageID)
        guard ids != savedOutbox else { return }
        savedOutbox = ids
        await outbox.save(pending, key: outboxKey)
    }
}
