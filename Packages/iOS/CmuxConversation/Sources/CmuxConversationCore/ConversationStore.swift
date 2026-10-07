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
    /// Unread count, read marker or catch-up target changed.
    case readState
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
    /// Everything from others at or below this seq has been read.
    public private(set) var lastReadSeq = 0
    /// Messages from others after `lastReadSeq` (including ones above the loaded window).
    public private(set) var unreadCount = 0
    /// The read marker as it stood when the current viewing began with unread
    /// messages: the catch-up arrow jumps to the first message from others
    /// after it. Nil when there is nothing to catch up on.
    public private(set) var catchUpMarker: Int?
    /// How many messages were unread when the current viewing began.
    public private(set) var catchUpCount = 0
    /// The conversation is on screen in a foreground window: arrivals are read
    /// (and receipts sent) as they land, as in Messages.
    public private(set) var isViewing = false
    private var serverRead: ConversationReadState?
    private var catchUpCaptured = false

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
    /// Highest seq this device asked the service to mark read and the
    /// service has not yet confirmed; a confirmation below it is stale.
    private var pendingReadSeq = 0
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
            // Unconfirmed reads from the dropped session may never have
            // arrived; the read state that follows hello is authoritative.
            pendingReadSeq = 0
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
        case let .readState(state):
            serverRead = state
            if state.lastReadSeq >= pendingReadSeq {
                pendingReadSeq = 0
                lastReadSeq = state.lastReadSeq
            }
            refreshReadState()
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
        if isNew { refreshReadState() }
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
            // A failed send stays where it failed: after the newest stored
            // message at that moment. Comparing its local time with server times
            // misorders it behind my own earlier sends that the server stamped
            // later (sends go out one at a time).
            let position: Int
            if let anchor = failedAnchorSeq[message.id] {
                position = acked.firstIndex { ($0.seq ?? 0) > anchor } ?? acked.count
            } else {
                position = acked.firstIndex { $0.sentAt > message.sentAt } ?? acked.count
            }
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
        refreshReadState()
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
        refreshReadState()
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
        failedAnchorSeq[message.id] = nil
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
        failedAnchorSeq[messages[index].id] = nil
        messages.remove(at: index)
        sortAndReindex()
        notify(.live(insertedRowIDs: [], sentByMe: true))
    }

    /// The previous send's work; each send waits for it so the server numbers
    /// messages in the order they were sent (it assigns seq on arrival).
    private var sendTail: Task<Void, Never>?
    /// For each failed send, the newest stored seq when it failed.
    private var failedAnchorSeq: [String: Int] = [:]

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
                // Sending reads the conversation (the service moves the marker too).
                if let seq = acked.seq, seq > self.lastReadSeq {
                    self.lastReadSeq = seq
                    self.refreshReadState()
                }
            } catch {
                self.markFailed(clientID: clientID, reason: String(describing: error))
            }
        }
    }

    private func markFailed(clientID: String, reason: String) {
        guard let index = messages.firstIndex(where: { $0.clientMessageID == clientID }),
              messages[index].seq == nil else { return }
        messages[index].delivery = .failed(reason)
        failedAnchorSeq[messages[index].id] = messages.last { $0.seq != nil }?.seq ?? 0
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
        guard let newest = newestIncomingSeq else { return }
        markRead(through: newest)
    }

    // MARK: Read state and catch-up

    private var newestIncomingSeq: Int? {
        messages.last { $0.seq != nil && $0.senderID != meID }?.seq
    }

    /// Marks everything from others through `seq` read and sends the receipt.
    public func markRead(through seq: Int) {
        guard seq > lastReadSeq else { return }
        lastReadSeq = seq
        pendingReadSeq = max(pendingReadSeq, seq)
        Task { [backend] in await backend.markRead(upToSeq: seq) }
        refreshReadState()
    }

    /// The host reports whether this conversation is on screen in a
    /// foreground window. While it is, everything that arrives is read; the
    /// unread backlog found when viewing begins becomes the catch-up target.
    public func setViewing(_ viewing: Bool) {
        guard viewing != isViewing else { return }
        isViewing = viewing
        if !viewing {
            catchUpCaptured = false
            let hadCatchUp = catchUpMarker != nil
            catchUpMarker = nil
            catchUpCount = 0
            if hadCatchUp { notify(.readState) }
            return
        }
        refreshReadState()
    }

    /// The reader reached the first unread message (or tapped the arrow).
    public func dismissCatchUp() {
        guard catchUpMarker != nil else { return }
        catchUpMarker = nil
        catchUpCount = 0
        notify(.readState)
    }

    /// The first message from others after the catch-up marker, once the
    /// window reaches down to the marker (an unread message above the window
    /// is not the first one).
    public var catchUpTarget: ConversationMessage? {
        guard let marker = catchUpMarker,
              let oldest = messages.first(where: { $0.seq != nil })?.seq,
              oldest <= marker + 1 || older == .exhausted else { return nil }
        return messages.first { ($0.seq ?? 0) > marker && $0.senderID != meID }
    }

    /// Loads older pages until the catch-up target is in the window and
    /// returns its row id. Nil when there is no target or loading failed.
    public func loadCatchUpTarget() async -> String? {
        guard let marker = catchUpMarker else { return nil }
        guard await loadThrough(seq: marker + 1) else { return nil }
        guard catchUpMarker == marker else { return nil }
        return catchUpTarget?.rowID
    }

    /// Fetches history above the window until `seq` is loaded (or history
    /// ends), in pages of up to 200, retrying failures with backoff.
    public func loadThrough(seq target: Int) async -> Bool {
        var attempt = 0
        while !Task.isCancelled {
            await olderTask?.value
            guard hasLoadedNewest else { return false }
            guard let oldest = messages.first(where: { $0.seq != nil })?.seq else { return false }
            if oldest <= target || older == .exhausted { return true }
            older = .loading
            notify(.older)
            do {
                // A few messages of context above the target, as Messages shows.
                let limit = min(200, max(pageSize, oldest - target + 8))
                let page = try await backend.history(beforeSeq: oldest, limit: limit)
                applyOlder(page, expectedOldest: oldest)
                attempt = 0
            } catch {
                attempt += 1
                older = .idle
                notify(.older)
                if attempt > 4 { return false }
                try? await clock.sleep(for: Self.backoff(attempt))
            }
        }
        return false
    }

    /// Recomputes the unread count from the window (exact when it covers the
    /// marker) or the service's count plus later arrivals; while viewing,
    /// captures the catch-up target and reads everything.
    private func refreshReadState() {
        let before = (lastReadSeq, unreadCount, catchUpMarker)
        unreadCount = computeUnread()
        if isViewing, hasLoadedNewest {
            if !catchUpCaptured, serverRead != nil {
                catchUpCaptured = true
                if unreadCount > 0 {
                    catchUpMarker = lastReadSeq
                    catchUpCount = unreadCount
                }
            }
            if let newest = newestIncomingSeq, newest > lastReadSeq {
                lastReadSeq = newest
                pendingReadSeq = max(pendingReadSeq, newest)
                Task { [backend] in await backend.markRead(upToSeq: newest) }
                unreadCount = computeUnread()
            }
        }
        if before != (lastReadSeq, unreadCount, catchUpMarker) { notify(.readState) }
    }

    private func computeUnread() -> Int {
        // Unread is the service's notion; without its read state there is none.
        guard let serverRead else { return 0 }
        let oldestLoaded = hasLoadedNewest ? messages.first(where: { $0.seq != nil })?.seq : nil
        func incoming(after seq: Int) -> Int {
            messages.reduce(0) { $0 + (($1.seq ?? 0) > seq && $1.senderID != meID ? 1 : 0) }
        }
        if let oldestLoaded, lastReadSeq >= oldestLoaded - 1 || older == .exhausted {
            return incoming(after: lastReadSeq)
        }
        let base = serverRead.lastReadSeq == lastReadSeq ? serverRead.unreadCount : 0
        return base + (hasLoadedNewest ? incoming(after: max(serverRead.headSeq, lastReadSeq)) : 0)
    }
}

/// Unread totals across conversations: the iOS back-button count (every
/// other conversation) and the Dock badge (all of them).
@MainActor
public final class ConversationUnreadBadge {
    public let stores: [ConversationStore]
    public var onChange: (@MainActor () -> Void)?

    public init(stores: [ConversationStore]) {
        self.stores = stores
        for store in stores {
            store.addObserver { [weak self] change in
                guard change == .readState else { return }
                self?.onChange?()
            }
        }
    }

    public var total: Int { stores.reduce(0) { $0 + $1.unreadCount } }

    public func total(excluding store: ConversationStore) -> Int {
        stores.reduce(0) { $0 + ($1 === store ? 0 : $1.unreadCount) }
    }
}
