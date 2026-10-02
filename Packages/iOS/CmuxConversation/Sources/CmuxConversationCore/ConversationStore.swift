import Foundation

/// State of the older-history pager at the top of the transcript.
public enum ConversationOlderState: Sendable, Equatable {
    case idle
    case loading
    /// A fetch failed; another attempt is scheduled while the reader stays near the top.
    case retrying(attempt: Int)
    case exhausted
}

public enum ConversationConnectionState: Sendable, Equatable {
    case connecting
    case connected
    case reconnecting
}

/// What changed, so the transcript can anchor scrolling correctly.
public enum ConversationStoreChange: Sendable, Equatable {
    /// The whole window was replaced (first load, lagged rebase).
    case reset
    /// Older history was inserted above everything loaded.
    case prepended
    /// Live traffic: new rows at the bottom and/or in-place updates.
    case live(insertedRowIDs: [String], sentByMe: Bool)
    case typing
    case older
    case connection
}

/// Backend-agnostic transcript state: one ordered window of messages that
/// always contains the newest message, grows upward as older pages load, and
/// absorbs live events (deduped, idempotent) plus optimistic local sends.
@MainActor
public final class ConversationStore {
    public private(set) var info: ConversationInfo?
    public private(set) var meID: String?
    /// Acknowledged messages ascend by seq; pending sends follow in creation order.
    public private(set) var messages: [ConversationMessage] = []
    public private(set) var older: ConversationOlderState = .idle
    public private(set) var hasLoadedNewest = false
    public private(set) var typingParticipantIDs: [String] = []
    public private(set) var connection: ConversationConnectionState = .connecting

    public var onChange: (@MainActor (ConversationStoreChange) -> Void)? {
        get { primaryObserver }
        set { primaryObserver = newValue }
    }
    private var primaryObserver: (@MainActor (ConversationStoreChange) -> Void)?
    private var observers: [@MainActor (ConversationStoreChange) -> Void] = []

    /// Additional listeners (a sidebar preview, a window title) beside `onChange`.
    public func addObserver(_ observer: @escaping @MainActor (ConversationStoreChange) -> Void) {
        observers.append(observer)
    }

    private func notify(_ change: ConversationStoreChange) {
        primaryObserver?(change)
        for observer in observers { observer(change) }
    }

    public let pageSize: Int
    private let backend: any ConversationBackend
    private let clock: any Clock<Duration>
    private let makeClientMessageID: @Sendable () -> String

    private var lastEventSeq = 0
    private var indexByID: [String: Int] = [:]
    private var eventTask: Task<Void, Never>?
    private var olderTask: Task<Void, Never>?
    private var newestTask: Task<Void, Never>?
    private var typingExpiry: [String: Task<Void, Never>] = [:]
    private var olderWanted = false
    private var markedReadSeq = 0
    private var localTyping = false
    private var localTypingTask: Task<Void, Never>?
    private var bufferedLive: [ConversationMessage] = []

    public init(
        backend: any ConversationBackend,
        pageSize: Int = 40,
        clock: any Clock<Duration> = ContinuousClock(),
        makeClientMessageID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.backend = backend
        self.pageSize = pageSize
        self.clock = clock
        self.makeClientMessageID = makeClientMessageID
    }

    public func start() {
        guard eventTask == nil else { return }
        let stream = backend.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    public func stop() {
        eventTask?.cancel()
        olderTask?.cancel()
        newestTask?.cancel()
        localTypingTask?.cancel()
        typingExpiry.values.forEach { $0.cancel() }
        backend.close()
    }

    public var me: ConversationParticipant? { meID.flatMap { info?.participant($0) } }

    public func message(id: String) -> ConversationMessage? {
        indexByID[id].map { messages[$0] }
    }

    public func message(rowID: String) -> ConversationMessage? {
        messages.first { $0.rowID == rowID }
    }

    // MARK: Backend events

    func apply(_ event: ConversationBackendEvent) {
        switch event {
        case let .connected(info, meID, lagged):
            self.info = info
            self.meID = meID
            connection = .connected
            notify(.connection)
            if lagged || !hasLoadedNewest {
                loadNewest(rebase: lagged)
            }
        case let .message(message, eventSeq):
            guard eventSeq > lastEventSeq else { return }
            lastEventSeq = eventSeq
            ingestLive(message)
        case let .typing(participantID, isTyping):
            setTyping(participantID, isTyping)
        case .disconnected:
            connection = .reconnecting
            notify(.connection)
        }
    }

    /// Replays a live event held during the initial load: newer messages and
    /// updates to loaded ones apply; anything above the window is dropped.
    private func ingestBuffered(_ incoming: ConversationMessage) {
        if indexByID[incoming.id] == nil, let seq = incoming.seq,
           let oldest = messages.first(where: { $0.seq != nil })?.seq, seq < oldest {
            return
        }
        if upsert(incoming) { sortAndReindex() }
    }

    private func ingestLive(_ incoming: ConversationMessage) {
        // Until the newest page lands there is no window to judge against;
        // hold live traffic and replay it through the same rules afterwards.
        guard hasLoadedNewest else {
            bufferedLive.append(incoming)
            return
        }
        // An edit, tapback or receipt for a message above the loaded window
        // must not pull it into the transcript (that would leave a gap); the
        // page that contains it will carry its current state.
        if indexByID[incoming.id] == nil, let seq = incoming.seq,
           let oldest = messages.first(where: { $0.seq != nil })?.seq, seq < oldest {
            return
        }
        let isNew = upsert(incoming)
        if isNew {
            sortAndReindex()
            // The typing bubble leaves in the same update the message arrives,
            // so the transcript moves once.
            if incoming.senderID != meID, typingParticipantIDs.contains(incoming.senderID) {
                clearTyping(incoming.senderID, notify: false)
            }
        }
        // Only sends from this device count as "mine" for scrolling; the same
        // account on another device behaves like any other sender.
        notify(.live(insertedRowIDs: isNew ? [incoming.rowID] : [], sentByMe: false))
    }

    /// Inserts or merges a message. Returns true when a new row appeared.
    @discardableResult
    private func upsert(_ incoming: ConversationMessage) -> Bool {
        if let index = indexByID[incoming.id] {
            messages[index] = merged(existing: messages[index], incoming: incoming)
            return false
        }
        if let clientID = incoming.clientMessageID,
           let index = indexByID["local:\(clientID)"] {
            let pendingID = messages[index].id
            messages[index] = merged(existing: messages[index], incoming: incoming)
            indexByID[pendingID] = nil
            indexByID[incoming.id] = index
            sortAndReindex()
            return false
        }
        messages.append(incoming)
        indexByID[incoming.id] = messages.count - 1
        return true
    }

    private func merged(existing: ConversationMessage, incoming: ConversationMessage) -> ConversationMessage {
        var result = incoming
        result.delivery = Self.maxDelivery(existing.delivery, incoming.delivery)
        // Keep local bytes so the sender's image never flashes while the remote copy loads.
        result.attachments = incoming.attachments.enumerated().map { offset, attachment in
            var attachment = attachment
            if attachment.localData == nil, offset < existing.attachments.count {
                attachment.localData = existing.attachments[offset].localData
            }
            return attachment
        }
        if incoming.attachments.isEmpty, !existing.attachments.isEmpty, incoming.seq == nil {
            result.attachments = existing.attachments
        }
        return result
    }

    static func deliveryRank(_ delivery: ConversationDelivery?) -> Int {
        switch delivery {
        case nil: return -1
        case .failed: return 0
        case .sending: return 1
        case .sent: return 2
        case .delivered: return 3
        case .read: return 4
        }
    }

    static func maxDelivery(_ lhs: ConversationDelivery?, _ rhs: ConversationDelivery?) -> ConversationDelivery? {
        // An acknowledgment always clears a local failure; otherwise never regress.
        if case .failed = lhs, rhs != nil { return rhs }
        return deliveryRank(rhs) >= deliveryRank(lhs) ? rhs : lhs
    }

    /// Acknowledged messages ascend by seq. A failed send keeps its place in
    /// time (later arrivals go below it); sends still in flight stay last.
    private func sortAndReindex() {
        var acked = messages.filter { $0.seq != nil }.sorted { $0.seq! < $1.seq! }
        let failed = messages.filter { $0.seq == nil && $0.delivery?.isFailed == true }.sorted { $0.sentAt < $1.sentAt }
        let inFlight = messages.filter { $0.seq == nil && $0.delivery?.isFailed != true }.sorted { $0.sentAt < $1.sentAt }
        for message in failed.reversed() {
            let position = acked.firstIndex { $0.sentAt > message.sentAt } ?? acked.count
            acked.insert(message, at: position)
        }
        messages = acked + inFlight
        indexByID.removeAll(keepingCapacity: true)
        for (index, message) in messages.enumerated() {
            indexByID[message.id] = index
        }
    }

    // MARK: Typing

    private func setTyping(_ participantID: String, _ isTyping: Bool) {
        guard participantID != meID else { return }
        if isTyping {
            if !typingParticipantIDs.contains(participantID) {
                typingParticipantIDs.append(participantID)
                notify(.typing)
            }
            typingExpiry[participantID]?.cancel()
            let clock = clock
            typingExpiry[participantID] = Task { [weak self] in
                // A typing signal that is never cleared (dropped socket) fades out.
                try? await clock.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                self?.clearTyping(participantID)
            }
        } else if typingParticipantIDs.contains(participantID) {
            // Services clear typing just before delivering the message. Holding
            // the indicator briefly lets the message replace it in one update
            // (ingestLive clears it silently) instead of collapse-then-insert.
            typingExpiry[participantID]?.cancel()
            let clock = clock
            typingExpiry[participantID] = Task { [weak self] in
                try? await clock.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { return }
                self?.clearTyping(participantID)
            }
        }
    }

    private func clearTyping(_ participantID: String, notify: Bool = true) {
        typingExpiry[participantID]?.cancel()
        typingExpiry[participantID] = nil
        guard let index = typingParticipantIDs.firstIndex(of: participantID) else { return }
        typingParticipantIDs.remove(at: index)
        if notify { self.notify(.typing) }
    }

    // MARK: History

    private func loadNewest(rebase: Bool) {
        newestTask?.cancel()
        newestTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let page = try await self.backend.history(beforeSeq: nil, limit: self.pageSize)
                    self.applyNewest(page, rebase: rebase)
                    return
                } catch {
                    attempt += 1
                    try? await self.clock.sleep(for: Self.backoff(attempt))
                }
            }
        }
    }

    private func applyNewest(_ page: ConversationHistoryPage, rebase: Bool) {
        if rebase || !hasLoadedNewest {
            let pending = messages.filter { $0.seq == nil }
            messages = []
            indexByID = [:]
            for message in page.messages { upsert(message) }
            for message in pending { upsert(message) }
            sortAndReindex()
        }
        hasLoadedNewest = true
        let buffered = bufferedLive
        bufferedLive = []
        for message in buffered { ingestBuffered(message) }
        older = page.hasMore ? .idle : .exhausted
        notify(.reset)
        if olderWanted { loadOlder() }
    }

    /// Requests the page above the oldest loaded message. Safe to call on
    /// every scroll tick; it coalesces and retries with backoff on failure.
    public func loadOlder() {
        olderWanted = true
        guard hasLoadedNewest else { return }
        switch older {
        case .loading, .retrying, .exhausted: return
        case .idle: break
        }
        guard let oldestSeq = messages.first(where: { $0.seq != nil })?.seq else {
            older = .exhausted
            notify(.older)
            return
        }
        older = .loading
        notify(.older)
        olderTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let page = try await self.backend.history(beforeSeq: oldestSeq, limit: self.pageSize)
                    self.applyOlder(page, expectedOldest: oldestSeq)
                    return
                } catch {
                    attempt += 1
                    self.older = .retrying(attempt: attempt)
                    self.notify(.older)
                    try? await self.clock.sleep(for: Self.backoff(attempt))
                    guard self.olderWanted else {
                        self.older = .idle
                        self.notify(.older)
                        return
                    }
                }
            }
        }
    }

    /// The reader left the top region; a failed fetch stops retrying.
    public func olderNoLongerWanted() {
        olderWanted = false
    }

    private func applyOlder(_ page: ConversationHistoryPage, expectedOldest: Int) {
        olderWanted = false
        var inserted = false
        for message in page.messages where indexByID[message.id] == nil {
            guard let seq = message.seq, seq < expectedOldest else { continue }
            messages.append(message)
            inserted = true
        }
        if inserted { sortAndReindex() }
        older = page.hasMore ? .idle : .exhausted
        notify(.prepended)
    }

    static func backoff(_ attempt: Int) -> Duration {
        .milliseconds(min(8000, 500 * (1 << min(attempt, 4))))
    }

    // MARK: Sending

    /// Appends the optimistic row at once, then uploads and sends.
    @discardableResult
    public func send(text: String, images: [(data: Data, width: Int, height: Int, mimeType: String)] = [], replyToID: String? = nil) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !images.isEmpty), let meID else { return nil }
        let clientID = makeClientMessageID()
        let attachments = images.enumerated().map { offset, image in
            ConversationAttachment(
                id: "local:\(clientID):\(offset)",
                kind: .image,
                width: image.width,
                height: image.height,
                url: nil,
                localData: image.data
            )
        }
        let pending = ConversationMessage(
            id: "local:\(clientID)",
            seq: nil,
            clientMessageID: clientID,
            senderID: meID,
            sentAt: Date(),
            text: trimmed,
            replyToID: replyToID,
            attachments: attachments,
            delivery: .sending
        )
        upsert(pending)
        sortAndReindex()
        notify(.live(insertedRowIDs: [pending.rowID], sentByMe: true))
        setLocalTyping(false)
        transmit(clientID: clientID, images: images)
        return pending.rowID
    }

    /// Re-sends a failed message with the same client id (server dedupes).
    public func retry(rowID: String) {
        guard let message = message(rowID: rowID), message.delivery?.isFailed == true,
              let clientID = message.clientMessageID,
              let index = indexByID[message.id] else { return }
        messages[index].delivery = .sending
        notify(.live(insertedRowIDs: [], sentByMe: true))
        let images = message.attachments.compactMap { attachment -> (data: Data, width: Int, height: Int, mimeType: String)? in
            guard let data = attachment.localData else { return nil }
            return (data, attachment.width, attachment.height, "image/jpeg")
        }
        transmit(clientID: clientID, images: images)
    }

    /// Removes a failed local send (never acknowledged by the server).
    public func discardFailed(rowID: String) {
        guard let index = messages.firstIndex(where: { $0.rowID == rowID }),
              messages[index].seq == nil, messages[index].delivery?.isFailed == true else { return }
        messages.remove(at: index)
        sortAndReindex()
        notify(.live(insertedRowIDs: [], sentByMe: true))
    }

    /// The previous send's work; each send waits for it so the server numbers
    /// messages in the order they were sent (it assigns seq on arrival).
    private var sendTail: Task<Void, Never>?

    private func transmit(clientID: String, images: [(data: Data, width: Int, height: Int, mimeType: String)]) {
        let previous = sendTail
        sendTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                var attachmentIDs: [String] = []
                for image in images {
                    let uploaded = try await self.backend.uploadImage(image.data, mimeType: image.mimeType)
                    attachmentIDs.append(uploaded.id)
                }
                guard let current = self.message(id: "local:\(clientID)") ?? self.messages.first(where: { $0.clientMessageID == clientID }) else { return }
                let draft = ConversationOutgoingDraft(
                    clientMessageID: clientID,
                    text: current.text,
                    replyToID: current.replyToID,
                    attachmentIDs: attachmentIDs
                )
                var acked = try await self.backend.send(draft)
                if acked.delivery == nil { acked.delivery = .sent }
                if self.upsert(acked) { self.sortAndReindex() }
                self.notify(.live(insertedRowIDs: [], sentByMe: true))
            } catch {
                self.markFailed(clientID: clientID, reason: String(describing: error))
            }
        }
    }

    private func markFailed(clientID: String, reason: String) {
        guard let index = messages.firstIndex(where: { $0.clientMessageID == clientID }),
              messages[index].seq == nil else { return }
        messages[index].delivery = .failed(reason)
        notify(.live(insertedRowIDs: [], sentByMe: true))
    }

    // MARK: Reactions, typing, read

    public func react(messageID: String, reaction: ConversationReaction?) {
        guard let meID, let index = indexByID[messageID] else { return }
        var message = messages[index]
        message.reactions.removeAll { $0.participantID == meID }
        if let reaction {
            message.reactions.append(ConversationReactionMark(participantID: meID, reaction: reaction))
        }
        messages[index] = message
        notify(.live(insertedRowIDs: [], sentByMe: true))
        Task { [weak self] in
            guard let self else { return }
            if let updated = try? await self.backend.react(messageID: messageID, reaction: reaction) {
                self.upsert(updated)
                self.notify(.live(insertedRowIDs: [], sentByMe: false))
            }
        }
    }

    /// Messages lets you edit your own message for 15 minutes after sending.
    public static let editWindow: TimeInterval = 15 * 60

    public func canEdit(_ message: ConversationMessage, now: Date = Date()) -> Bool {
        message.senderID == meID && message.seq != nil && message.attachments.isEmpty
            && now.timeIntervalSince(message.sentAt) < Self.editWindow
    }

    /// Applies the edit at once; reverts if the backend refuses it.
    public func edit(messageID: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = indexByID[messageID], messages[index].text != trimmed else { return }
        let original = messages[index]
        messages[index].text = trimmed
        messages[index].editedAt = Date()
        notify(.live(insertedRowIDs: [], sentByMe: false))
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await self.backend.edit(messageID: messageID, text: trimmed)
                self.upsert(updated)
            } catch {
                guard let index = self.indexByID[messageID] else { return }
                self.messages[index] = original
            }
            self.notify(.live(insertedRowIDs: [], sentByMe: true))
        }
    }

    /// Composer text changed. Typing stays on while edits keep coming.
    public func composerTextChanged(isEmpty: Bool) {
        setLocalTyping(!isEmpty)
    }

    private func setLocalTyping(_ isTyping: Bool) {
        localTypingTask?.cancel()
        if isTyping {
            let clock = clock
            localTypingTask = Task { [weak self] in
                try? await clock.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.setLocalTyping(false)
            }
        }
        guard isTyping != localTyping else { return }
        localTyping = isTyping
        Task { [backend] in await backend.setTyping(isTyping) }
    }

    /// Called while the newest message is on screen.
    public func markNewestRead() {
        guard let newest = messages.last(where: { $0.seq != nil && $0.senderID != meID })?.seq,
              newest > markedReadSeq else { return }
        markedReadSeq = newest
        Task { [backend] in await backend.markRead(upToSeq: newest) }
    }
}
