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
    /// Pin, Hide Alerts, Mark as Unread or delete changed; the transcript is unaffected.
    case listState
    /// The conversation background changed (here, on another device, or by
    /// someone else); only the backdrop and its contrast are affected.
    case background
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
    /// Messages pages history 50 messages at a time on iPhone
    /// (CKUIBehavior.defaultConversationLoadMoreCount); the Mac pages 100.
    public static let defaultPageSize = 50
    public static let macPageSize = 100
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
    /// Bumps on every list state change so a stale reply or rollback never
    /// overwrites a newer state.
    private var listStateGeneration = 0
    /// Bumps on every background I set, so only the newest answer applies.
    private var backgroundGeneration = 0
    private var backgroundInFlight = false

    public init(
        backend: any ConversationBackend,
        pageSize: Int = ConversationStore.defaultPageSize,
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
            let previousBackground = self.info?.background
            self.info = info
            self.info?.background = reconciledBackground(incoming: info.background, current: previousBackground)
            if self.info?.background != previousBackground { notify(.background) }
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
        case let .conversationChanged(info):
            listStateGeneration += 1
            let previousBackground = self.info?.background
            self.info = info
            self.info?.background = reconciledBackground(incoming: info.background, current: previousBackground)
            notify(.listState)
            if self.info?.background != previousBackground { notify(.background) }
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
        // Deleted on this device: no update, ack or refetch brings it back.
        if deletedMessageIDs.contains(incoming.id) || incoming.clientMessageID.map(deletedClientIDs.contains) == true {
            return false
        }
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
        if result.effect == nil, incoming.seq == nil || existing.seq == nil { result.effect = existing.effect }
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
        // Unsending is final: a stale echo of the original never brings the
        // text back (a refused unsend restores the original directly).
        if let unsentAt = existing.unsentAt, incoming.unsentAt == nil {
            result.unsentAt = unsentAt
            result.text = ""
            result.attachments = []
            result.reactions = []
        }
        // A preview loaded here (composer, tap to load) outlives an echo that lacks it.
        if let local = existing.linkPreview, local.state != .tapToLoad,
           incoming.linkPreview == nil || (incoming.linkPreview?.state == .tapToLoad && incoming.linkPreview?.url == local.url),
           ConversationLinkSplit.split(text: incoming.text, preview: local) != nil {
            result.linkPreview = local
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
        for message in page.messages where indexByID[message.id] == nil && !deletedMessageIDs.contains(message.id) {
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
    public func send(
        text: String,
        images: [(data: Data, width: Int, height: Int, mimeType: String)] = [],
        replyToID: String? = nil,
        mentions: [ConversationMention] = [],
        textRuns: [ConversationTextRun] = [],
        linkPreview: ConversationLinkPreview? = nil,
        effect: ConversationMessageEffect? = nil
    ) -> String? {
        let (trimmed, runs) = ConversationRichText.trimmed(text, runs: textRuns)
        guard (!trimmed.isEmpty || !images.isEmpty), let meID else { return nil }
        let leading = text.prefix { $0.isWhitespace || $0.isNewline }.utf16.count
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
            delivery: .sending,
            mentions: ConversationMentionEditing.trimmed(mentions, removedPrefix: leading, textLength: trimmed.utf16.count),
            textRuns: runs,
            linkPreview: linkPreview,
            effect: effect
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
        // Try Again is a send made now: the row leaves its failed place for
        // the bottom, with the other sends in flight.
        messages[index].sentAt = Date()
        failedAnchorSeq[message.id] = nil
        sortAndReindex()
        notify(.live(insertedRowIDs: [], sentByMe: true))
        let images = message.attachments.compactMap { attachment -> (data: Data, width: Int, height: Int, mimeType: String)? in
            guard let data = attachment.localData else { return nil }
            return (data, attachment.width, attachment.height, "image/jpeg")
        }
        let audio = message.audioAttachment.flatMap { attachment -> PendingAudio? in
            guard let data = attachment.localData, let info = attachment.audio else { return nil }
            return PendingAudio(data: data, mimeType: Self.audioMimeType(data), info: info)
        }
        transmit(clientID: clientID, images: message.audioAttachment == nil ? images : [], audio: audio)
    }

    /// Removes a failed local send (never acknowledged by the server).
    public func discardFailed(rowID: String) {
        guard let message = message(rowID: rowID), message.seq == nil, message.delivery?.isFailed == true else { return }
        deleteLocally(rowIDs: [rowID])
    }

    /// Delete for me (select mode's trash, a failed send's Delete): the rows
    /// leave this device's transcript for good; nothing is sent. A send still
    /// in flight is dropped when its ack arrives.
    public func deleteLocally(rowIDs: Set<String>) {
        let doomed = messages.filter { rowIDs.contains($0.rowID) }
        guard !doomed.isEmpty else { return }
        for message in doomed {
            deletedMessageIDs.insert(message.id)
            if let clientID = message.clientMessageID { deletedClientIDs.insert(clientID) }
            failedAnchorSeq[message.id] = nil
            unsendOriginals[message.id] = nil
        }
        messages.removeAll { rowIDs.contains($0.rowID) }
        sortAndReindex()
        notify(.live(insertedRowIDs: [], sentByMe: false))
    }

    private var deletedMessageIDs: Set<String> = []
    private var deletedClientIDs: Set<String> = []

    /// The previous send's work; each send waits for it so the server numbers
    /// messages in the order they were sent (it assigns seq on arrival).
    private var sendTail: Task<Void, Never>?
    /// For each failed send, the newest stored seq when it failed.
    private var failedAnchorSeq: [String: Int] = [:]

    private func transmit(clientID: String, images: [(data: Data, width: Int, height: Int, mimeType: String)], audio: PendingAudio? = nil) {
        let previous = sendTail
        sendTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                var attachmentIDs: [String] = []
                if let audio {
                    let uploaded = try await self.backend.uploadAudio(audio.data, mimeType: audio.mimeType, info: audio.info)
                    attachmentIDs.append(uploaded.id)
                }
                for image in images {
                    let uploaded = try await self.backend.uploadImage(image.data, mimeType: image.mimeType)
                    attachmentIDs.append(uploaded.id)
                }
                guard let current = self.message(id: "local:\(clientID)") ?? self.messages.first(where: { $0.clientMessageID == clientID }) else { return }
                let draft = ConversationOutgoingDraft(
                    clientMessageID: clientID,
                    text: current.text,
                    replyToID: current.replyToID,
                    attachmentIDs: attachmentIDs,
                    mentions: current.mentions,
                    textRuns: current.textRuns,
                    effect: current.effect
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

    // MARK: Audio messages

    struct PendingAudio: Sendable {
        var data: Data
        var mimeType: String
        var info: ConversationAudioInfo
    }

    static func audioMimeType(_ data: Data) -> String {
        data.prefix(4) == Data("RIFF".utf8) ? "audio/wav" : "audio/mp4"
    }

    /// Sends a recorded audio message (alone, as Messages does). The row
    /// appears at once with the local recording, so it plays before upload.
    @discardableResult
    public func sendAudio(data: Data, info: ConversationAudioInfo, replyToID: String? = nil) -> String? {
        guard let meID, !data.isEmpty else { return nil }
        let clientID = makeClientMessageID()
        var localInfo = info
        localInfo.expiresAt = nil
        let attachment = ConversationAttachment(
            id: "local:\(clientID):audio",
            kind: .audio,
            width: 0,
            height: 0,
            url: nil,
            localData: data,
            audio: localInfo
        )
        let pending = ConversationMessage(
            id: "local:\(clientID)",
            seq: nil,
            clientMessageID: clientID,
            senderID: meID,
            sentAt: Date(),
            text: "",
            replyToID: replyToID,
            attachments: [attachment],
            delivery: .sending
        )
        upsert(pending)
        sortAndReindex()
        notify(.live(insertedRowIDs: [pending.rowID], sentByMe: true))
        setLocalTyping(false)
        transmit(clientID: clientID, images: [], audio: PendingAudio(data: data, mimeType: Self.audioMimeType(data), info: info))
        return pending.rowID
    }

    /// Keep: the recording no longer expires on this device.
    public func keepAudio(messageID: String) {
        guard let index = indexByID[messageID],
              let offset = messages[index].attachments.firstIndex(where: { $0.kind == .audio }) else { return }
        messages[index].attachments[offset].audio?.isKept = true
        messages[index].attachments[offset].audio?.expiresAt = nil
        notify(.live(insertedRowIDs: [], sentByMe: false))
        guard messages[index].seq != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            if let updated = try? await self.backend.keepAudio(messageID: messageID) {
                self.upsert(updated)
                self.notify(.live(insertedRowIDs: [], sentByMe: false))
            }
        }
    }

    /// The reader listened to someone's audio message to the end.
    public func audioPlayed(messageID: String) {
        guard let message = message(id: messageID), message.seq != nil, message.senderID != meID,
              message.audioAttachment?.audio?.isKept != true else { return }
        Task { [backend] in await backend.audioPlayed(messageID: messageID) }
    }

    // MARK: Link previews

    /// Composer preview for a URL being typed, fetched through the backend.
    public func fetchLinkPreview(for url: URL) async -> ConversationLinkPreview? {
        try? await backend.linkPreview(for: url)
    }

    /// Tap to Load Preview: fetches the card for a message from an unknown sender.
    public func loadLinkPreview(messageID: String) {
        guard let index = indexByID[messageID], let preview = messages[index].linkPreview, preview.state == .tapToLoad else { return }
        messages[index].linkPreview?.state = .loading
        notify(.live(insertedRowIDs: [], sentByMe: false))
        Task { [weak self] in
            guard let self else { return }
            let loaded = try? await self.backend.linkPreview(for: preview.url)
            guard let index = self.indexByID[messageID] else { return }
            var result = loaded ?? ConversationLinkPreview(url: preview.url)
            result.state = .loaded
            self.messages[index].linkPreview = result
            self.notify(.live(insertedRowIDs: [], sentByMe: false))
        }
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

    /// Messages lets you edit your own message for 15 minutes after sending,
    /// up to five times.
    public static let editWindow: TimeInterval = 15 * 60
    public static let maxEdits = 5

    public func canEdit(_ message: ConversationMessage, now: Date = Date()) -> Bool {
        message.senderID == meID && message.seq != nil && message.attachments.isEmpty && !message.isNotice
            && message.editCount < Self.maxEdits && now.timeIntervalSince(message.sentAt) < Self.editWindow
    }

    /// Applies the edit at once; reverts if the backend refuses it.
    /// `textRuns` are the edited text's formatting; omitting them clears it.
    /// Mentions survive only where their text is unchanged.
    public func edit(messageID: String, text: String, textRuns: [ConversationTextRun] = []) {
        let (trimmed, runs) = ConversationRichText.trimmed(text, runs: textRuns)
        guard !trimmed.isEmpty, let index = indexByID[messageID],
              messages[index].text != trimmed || messages[index].textRuns != runs,
              canEdit(messages[index]) else { return }
        let original = messages[index]
        messages[index].text = trimmed
        messages[index].textRuns = runs
        messages[index].mentions = ConversationMentionEditing.surviving(original.mentions, oldText: original.text, newText: trimmed)
        messages[index].editedAt = Date()
        messages[index].editCount += 1
        notify(.live(insertedRowIDs: [], sentByMe: false))
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await self.backend.edit(messageID: messageID, text: trimmed, textRuns: runs)
                self.upsert(updated)
            } catch {
                guard let index = self.indexByID[messageID] else { return }
                self.messages[index] = original
            }
            self.notify(.live(insertedRowIDs: [], sentByMe: true))
        }
    }

    /// Messages lets you take a message back for 2 minutes after sending.
    public static let undoSendWindow: TimeInterval = 2 * 60

    public func canUnsend(_ message: ConversationMessage, now: Date = Date()) -> Bool {
        message.senderID == meID && message.seq != nil && !message.isNotice
            && now.timeIntervalSince(message.sentAt) < Self.undoSendWindow
    }

    /// The pre-unsend message, kept until the backend confirms.
    private var unsendOriginals: [String: ConversationMessage] = [:]

    /// Undo Send: the bubble becomes a notice at once; the original comes
    /// back if the backend refuses (for example, the window closed).
    public func unsend(messageID: String) {
        guard let index = indexByID[messageID], canUnsend(messages[index]) else { return }
        unsendOriginals[messageID] = messages[index]
        messages[index].unsentAt = Date()
        messages[index].text = ""
        messages[index].attachments = []
        messages[index].reactions = []
        notify(.live(insertedRowIDs: [], sentByMe: false))
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await self.backend.unsend(messageID: messageID)
                self.unsendOriginals[messageID] = nil
                self.upsert(updated)
            } catch {
                guard let original = self.unsendOriginals.removeValue(forKey: messageID),
                      let index = self.indexByID[messageID] else { return }
                self.messages[index] = original
            }
            self.notify(.live(insertedRowIDs: [], sentByMe: false))
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
    /// unread backlog found when the visit begins becomes the catch-up
    /// target. Going inactive (app switch, occlusion) keeps the visit.
    public func setViewing(_ viewing: Bool) {
        guard viewing != isViewing else { return }
        isViewing = viewing
        // Coming back from the background, messages that arrived meanwhile
        // are a backlog of their own (ChatKit re-checks on resume).
        if !viewing { catchUpCaptured = false }
        if viewing { refreshReadState() }
    }

    /// The reader left the conversation (back, another conversation
    /// selected): the catch-up target ends; the next visit finds its own.
    public func endVisit() {
        isViewing = false
        catchUpCaptured = false
        guard catchUpMarker != nil else { return }
        catchUpMarker = nil
        catchUpCount = 0
        notify(.readState)
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
                // An earlier target still pending stays: it is the older one.
                if unreadCount > 0, catchUpMarker == nil {
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
            messages.reduce(0) { $0 + (($1.seq ?? 0) > seq && $1.senderID != meID && $1.systemEvent == nil ? 1 : 0) }
        }
        if let oldestLoaded, lastReadSeq >= oldestLoaded - 1 || older == .exhausted {
            return incoming(after: lastReadSeq)
        }
        let base = serverRead.lastReadSeq == lastReadSeq ? serverRead.unreadCount : 0
        return base + (hasLoadedNewest ? incoming(after: max(serverRead.headSeq, lastReadSeq)) : 0)
    }
    // MARK: Conversation background (state)

    /// A re-delivery of the current background keeps the local copy (and a
    /// photo's picked bytes); while a set of mine is in flight, the pending
    /// one stays until the backend answers.
    private func reconciledBackground(incoming: ConversationBackground?, current: ConversationBackground?) -> ConversationBackground? {
        if backgroundInFlight { return current }
        guard let incoming, let current, incoming.id == current.id else { return incoming }
        return current
    }

    private func commitBackground(
        _ optimistic: ConversationBackground?,
        rejected: (@MainActor (ConversationBackendError) -> Void)?,
        perform: @escaping @Sendable (any ConversationBackend) async throws -> ConversationInfo
    ) {
        guard var current = info else { return }
        let previous = current.background
        backgroundGeneration += 1
        let generation = backgroundGeneration
        current.background = optimistic
        info = current
        notify(.background)
        backgroundInFlight = true
        Task { [weak self, backend] in
            do {
                let confirmed = try await perform(backend)
                guard let self, self.backgroundGeneration == generation, var latest = self.info else { return }
                self.backgroundInFlight = false
                var background = confirmed.background
                // Keep the picked bytes so the photo never reloads from the network.
                if background?.kind == .photo, let local = optimistic?.photo?.localData {
                    background?.photo?.localData = local
                }
                latest.background = background
                self.info = latest
                self.notify(.background)
            } catch {
                rejected?(error as? ConversationBackendError ?? ConversationBackendError(code: -1, message: String(describing: error)))
                guard let self, self.backgroundGeneration == generation, var latest = self.info else { return }
                self.backgroundInFlight = false
                latest.background = previous
                self.info = latest
                self.notify(.background)
            }
        }
    }

    // MARK: Conversation list state

    /// Pin, Hide Alerts, Mark as Unread and delete state; default until connected.
    public var listState: ConversationListState { info?.listState ?? ConversationListState() }

    /// Applies a list action at once and confirms it with the backend. A
    /// rejected action (the pin limit, a network failure) rolls back unless a
    /// newer state arrived meanwhile. `rejected` receives the backend's error
    /// (code `-32004` is the pin limit, reached from another device).
    public func updateListState(_ change: ConversationListStateChange, rejected: (@MainActor (ConversationBackendError) -> Void)? = nil) {
        guard !change.isEmpty, var optimistic = info else { return }
        let previous = optimistic.listState
        optimistic.listState = previous.applying(change)
        guard optimistic.listState != previous else { return }
        listStateGeneration += 1
        let generation = listStateGeneration
        info = optimistic
        notify(.listState)
        Task { [weak self, backend] in
            do {
                let confirmed = try await backend.updateListState(change)
                guard let self, self.listStateGeneration == generation else { return }
                self.info = confirmed
                self.notify(.listState)
            } catch {
                rejected?(error as? ConversationBackendError ?? ConversationBackendError(code: -1, message: String(describing: error)))
                guard let self, self.listStateGeneration == generation, var current = self.info else { return }
                current.listState = previous
                self.info = current
                self.notify(.listState)
            }
        }
    }
}

// MARK: - Conversation background

extension ConversationStore {
    /// The shared background, nil when there is none.
    public var background: ConversationBackground? { info?.background }

    /// Whether the backend carries backgrounds (the picker hides otherwise).
    public var supportsBackgrounds: Bool { backend.supportsBackgrounds }

    /// Sets or (with nil) removes the background at once, then confirms it
    /// with the backend, which tells everyone and writes "You changed the
    /// background." A refusal rolls back unless a newer background arrived.
    public func setBackground(_ draft: ConversationBackgroundDraft?, rejected: (@MainActor (ConversationBackendError) -> Void)? = nil) {
        let optimistic = draft?.optimisticBackground(id: "local:\(makeClientMessageID())", setBy: meID)
        commitBackground(optimistic, rejected: rejected) { backend in
            try await backend.setBackground(draft)
        }
    }

    /// A photo background: shows the picked image at once, uploads it, then
    /// sets it. `luminance` is the image's (`ConversationBackground.luminance(of:)`),
    /// so every device derives the same transcript contrast.
    public func setBackgroundPhoto(
        _ data: Data,
        mimeType: String,
        width: Int,
        height: Int,
        luminance: Double,
        rejected: (@MainActor (ConversationBackendError) -> Void)? = nil
    ) {
        let draft = ConversationBackgroundDraft(kind: .photo, luminance: luminance)
        let optimistic = draft.optimisticBackground(
            id: "local:\(makeClientMessageID())",
            setBy: meID,
            photo: ConversationBackground.Photo(url: nil, width: width, height: height, localData: data)
        )
        commitBackground(optimistic, rejected: rejected) { backend in
            let uploaded = try await backend.uploadImage(data, mimeType: mimeType)
            var photoDraft = draft
            photoDraft.attachmentID = uploaded.id
            return try await backend.setBackground(photoDraft)
        }
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
