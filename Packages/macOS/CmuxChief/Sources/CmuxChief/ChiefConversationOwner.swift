public import CmuxHomeCore
public import Foundation

/// The in-process owner of Home's Chief conversations on this Mac.
///
/// It plays the conversation owner's part for ``ChiefLocalSource``: it
/// assigns seqs and revisions, applies each idempotency key once, keeps every
/// conversation in `conversations/<id>.jsonl` under the ``ChiefHome``, and
/// publishes ``HomeEvent``s after each commit. A user message starts a Chief
/// turn through the injected ``ChiefBrain``:
///
/// 1. The user's message commits (`.message`).
/// 2. The Chief's read cursor moves to it (`.conversationChanged`), the
///    read receipt, and the Chief starts typing (`.typing`).
/// 3. Text deltas stream as `.draft` updates; each finished text segment
///    commits as one Chief message whose client id is the draft's turn key.
/// 4. Tool calls commit as messages with a `.work` part that is updated in
///    place (running, then done or failed).
/// 5. Typing goes off. A failure posts a Chief message with the error.
///
/// One turn runs at a time per conversation. A message sent while a turn
/// runs commits at once and waits in a FIFO queue; each queued message gets
/// its own turn after the running one ends (its read receipt comes when its
/// turn starts). ``stopTurn(conversation:)`` ends only the running turn.
/// An approval the brain requests posts as an `.approval` part; the app
/// answers it with ``answerApproval(conversation:message:part:choice:)``. A
/// question part's answer (`HomeOp.answerQuestion`) goes to the Chief as
/// its next turn.
///
/// ```swift
/// let owner = try await ChiefConversationOwner.load(home: .resolve(), brain: brain) { input in
///     ChiefTurnContext(systemPrompt: prompt, workingDirectory: input.home.root)
/// }
/// let store = HomeStore(source: ChiefLocalSource(owner: owner))
/// ```
public actor ChiefConversationOwner {
    /// A conversation mutation could not be durably written. The owner keeps
    /// the diagnostic on `lastPersistenceError` and does not publish the
    /// failed mutation as a successful operation.
    public struct PersistenceError: Error, Hashable, Sendable, CustomStringConvertible {
        public let message: String

        public init(message: String) { self.message = message }
        public var description: String { message }
    }
    /// The participant id of the signed-in user.
    public static let userID = ParticipantID("me")
    /// The participant id of the default Chief.
    public static let chiefID = ParticipantID("agent_chief")
    /// The default Chief conversation, which always exists.
    public static let defaultConversationID = ConversationID("conv_chief")

    /// The home the owner reads and writes.
    public nonisolated let home: ChiefHome
    /// The user.
    public nonisolated let me: Participant
    /// The default Chief.
    public nonisolated let chief: Participant

    let brain: any ChiefBrain
    let allowRules: ChiefAllowRules
    let contextProvider: ChiefTurnContextProvider
    let now: @Sendable () -> Date
    let clock: any Clock<Duration>
    let blobs: ChiefBlobStore

    var conversations: [ConversationID: ChiefConversationState] = [:]
    var logs: [ConversationID: ChiefConversationLog] = [:]
    var inboxRev: Revision = 1
    /// Decided keys and their answers (this session; sends also dedupe by client id on disk).
    var ledger: [IdempotencyKey: (op: HomeOp, result: HomeOpResult)] = [:]
    var subscribers: [UUID: AsyncStream<HomeEvent>.Continuation] = [:]
    var workingSubscribers: [UUID: AsyncStream<Set<ConversationID>>.Continuation] = [:]
    /// Opaque cursor for control clients. It changes for in-place card edits
    /// and working-state changes as well as new messages, and never survives
    /// an owner restart. Read it before taking a snapshot so a concurrent
    /// mutation can only cause an extra refresh, never a missed update.
    public private(set) var changeCursor = UUID().uuidString
    /// Cursor for inbox rows. Draft deltas belong only to an open transcript
    /// and must not cause Home to rebuild every conversation preview.
    public private(set) var inboxChangeCursor = UUID().uuidString
    var running: [ConversationID: ChiefRunningTurn] = [:]
    var pending: [ConversationID: [ChiefPendingTurn]] = [:]
    /// A failed read-cursor write must not strand the FIFO queue. There is at
    /// most one retry task per conversation, and it is cancelled once the
    /// queued turn starts or the owner shuts down.
    var readCursorRetryTasks: [ConversationID: Task<Void, Never>] = [:]
    /// Each conversation's last finished turn (``lastTurnStats(in:)``).
    var lastTurns: [ConversationID: ChiefTurnStats] = [:]
    /// Conversations whose stopped turn waits for the brain's interrupt; no turn starts there meanwhile.
    var stopping: Set<ConversationID> = []
    /// The last persistence failure, for diagnostics.
    public private(set) var lastPersistenceError: String?

    /// What the load found wrong with the home's conversation files (damaged
    /// files kept aside, unreadable ones skipped), for diagnostics.
    public nonisolated let loadProblems: [String]

    /// Opens (or creates) the Chief home and loads its conversations on the
    /// caller's thread. The app uses ``load(home:brain:userDisplayName:now:context:)``,
    /// which reads the files on a background task.
    ///
    /// - Parameters:
    ///   - home: The Chief home; its directories are created.
    ///   - brain: Runs each turn.
    ///   - userDisplayName: The user's name; nil uses `NSFullUserName()`, or "You" (localized) when that is empty.
    ///   - now: The clock for message times (tests pass a fixed one).
    ///   - context: Builds each turn's prompt, working directory and environment.
    /// - Throws: A file system error when the home's directories cannot be created. A
    ///   damaged or unreadable conversation file never throws (``loadProblems``).
    public init(
        home: ChiefHome,
        brain: any ChiefBrain,
        userDisplayName: String? = nil,
        allowRules: ChiefAllowRules = ChiefAllowRules(),
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock(),
        context: @escaping ChiefTurnContextProvider
    ) throws {
        allowRules.load(home)
        let people = Self.participants(userDisplayName: userDisplayName)
        let loaded = try Self.loadConversations(home: home, me: people.me, chief: people.chief, now: now)
        self.init(home: home, brain: brain, allowRules: allowRules, me: people.me, chief: people.chief,
                  now: now, clock: clock, context: context, loaded: loaded)
    }

    init(home: ChiefHome, brain: any ChiefBrain, allowRules: ChiefAllowRules = ChiefAllowRules(), me: Participant, chief: Participant,
         now: @escaping @Sendable () -> Date, clock: any Clock<Duration> = ContinuousClock(),
         context: @escaping ChiefTurnContextProvider,
         loaded: ChiefLoadedConversations) {
        self.home = home
        self.brain = brain
        self.allowRules = allowRules
        self.contextProvider = context
        self.now = now
        self.clock = clock
        self.blobs = ChiefBlobStore(root: home.blobsDirectory)
        self.me = me
        self.chief = chief
        self.conversations = loaded.conversations
        self.logs = loaded.files.mapValues(ChiefConversationLog.init(url:))
        self.loadProblems = loaded.problems
    }

    static func file(for id: ConversationID, in home: ChiefHome) -> URL {
        let name = ChiefHome.component(of: id.rawValue) ?? "conversation"
        return home.conversationsDirectory.appendingPathComponent("\(name).jsonl")
    }

    // MARK: Events

    /// A new subscription to owner events: `.connection(.online)`, then
    /// `.inbox`, then every later event in owner order. Ends on ``shutdown()``.
    public func events() -> AsyncStream<HomeEvent> {
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        continuation.yield(.connection(.online))
        continuation.yield(.inbox(inboxSnapshot()))
        return stream
    }

    /// The conversations with a running turn: the current set first, then
    /// each change. Home shows Stop while its conversation is in the set.
    public func workingConversations() -> AsyncStream<Set<ConversationID>> {
        let (stream, continuation) = AsyncStream<Set<ConversationID>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        workingSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribeWorking(id) }
        }
        continuation.yield(Set(running.keys))
        return stream
    }

    /// Whether a turn runs in `conversation`.
    public func isWorking(_ conversation: ConversationID) -> Bool { running[conversation] != nil }

    /// Ends every turn, ends every subscription and shuts the brain down.
    public func shutdown() async {
        for task in readCursorRetryTasks.values { task.cancel() }
        readCursorRetryTasks.removeAll()
        pending.removeAll()
        let turns = running
        for id in turns.keys { finishTurn(id, failure: nil, stopped: true, startNext: false) }
        for turn in turns.values { turn.task?.cancel() }
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
        for continuation in workingSubscribers.values { continuation.finish() }
        workingSubscribers.removeAll()
        await brain.shutdown()
    }

    func publish(_ event: HomeEvent) {
        changeCursor = UUID().uuidString
        if case .draft = event {
            for continuation in subscribers.values { continuation.yield(event) }
            return
        }
        inboxChangeCursor = UUID().uuidString
        for continuation in subscribers.values { continuation.yield(event) }
    }

    /// Waits until any Chief state has changed since the caller's snapshot.
    /// Subscription and the initial cursor check share the actor, closing the
    /// gap between reading a snapshot and beginning the next long poll.
    public func waitForChange(after cursor: String) async {
        guard changeCursor == cursor else { return }
        let stream = events()
        for await _ in stream {
            if Task.isCancelled || changeCursor != cursor { return }
        }
    }

    /// Waits for an inbox-visible change, excluding streamed draft deltas.
    /// Home uses this cursor so a long reply does not trigger a full preview
    /// rebuild for every token.
    public func waitForInboxChange(after cursor: String) async {
        guard inboxChangeCursor == cursor else { return }
        let stream = events()
        for await event in stream {
            if Task.isCancelled { return }
            if case .draft = event { continue }
            if inboxChangeCursor != cursor { return }
        }
    }

    func notifyWorking() {
        let set = Set(running.keys)
        for continuation in workingSubscribers.values { continuation.yield(set) }
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }
    private func unsubscribeWorking(_ id: UUID) { workingSubscribers[id] = nil }

    func inboxSnapshot() -> InboxSnapshot {
        InboxSnapshot(me: me, conversations: conversations.values.map(\.summary), rev: inboxRev)
    }

    // MARK: Commits

    func conversationState(_ id: ConversationID) throws -> ChiefConversationState {
        guard let state = conversations[id] else { throw HomeRejection.invalid("unknown_conversation") }
        return state
    }

    /// Commits a new message, publishes it, and persists it.
    @discardableResult
    func commitMessage(in id: ConversationID, author: ParticipantID, parts: [MessagePart], key: IdempotencyKey,
                       threadRoot: MessageID? = nil) throws -> Message {
        var state = try conversationState(id)
        guard state.summary.participants.contains(where: { $0.id == author }) else { throw HomeRejection.notAuthorized }
        let created = now()
        let message = Message(id: Self.mintMessageID(), conversation: id, seq: state.summary.lastSeq + 1,
                              clientMessageID: key, author: author, parts: parts, createdAt: created,
                              replyTo: threadRoot.map { PartRef(message: $0) }, threadRoot: threadRoot)
        state.upsert(message)
        state.summary.updatedAt = max(state.summary.updatedAt, created)
        state.summary.rev += 1
        if author == me.id {
            state.summary.readCursors[me.id] = message.seq
            state.summary.readCursorTimes[me.id] = created
        }
        try persist(id, [.message(message), .summary(state.summary)])
        conversations[id] = state
        publish(.message(message, rev: state.summary.rev))
        return message
    }

    /// Changes a known message, publishes it, and persists it.
    @discardableResult
    func updateMessage(_ messageID: MessageID, in id: ConversationID, _ change: (inout Message) throws -> Void) throws -> Message {
        var state = try conversationState(id)
        guard var message = state.message(messageID) else { throw HomeRejection.invalid("unknown_message") }
        try change(&message)
        state.upsert(message)
        state.summary.rev += 1
        try persist(id, [.message(message), .summary(state.summary)])
        conversations[id] = state
        publish(.message(message, rev: state.summary.rev))
        return message
    }

    /// Changes a conversation's own summary fields (read cursors) on its stream.
    @discardableResult
    func updateConversation(_ id: ConversationID, _ change: (inout ConversationSummary) -> Void) throws -> Revision {
        var state = try conversationState(id)
        change(&state.summary)
        state.summary.rev += 1
        try persist(id, [.summary(state.summary)])
        conversations[id] = state
        publish(.conversationChanged(state.summary, stream: .conversation(id), rev: state.summary.rev))
        return state.summary.rev
    }

    /// Changes account inbox fields (pin, mute) on the inbox stream.
    func updateInbox(_ id: ConversationID, _ change: (inout ConversationSummary) -> Void) throws -> HomeOpResult {
        var state = try conversationState(id)
        change(&state.summary)
        let nextInboxRev = inboxRev + 1
        try persist(id, [.summary(state.summary)])
        inboxRev = nextInboxRev
        conversations[id] = state
        publish(.conversationChanged(state.summary, stream: .inbox, rev: inboxRev))
        return HomeOpResult(rev: inboxRev)
    }

    /// Moves `participant`'s read cursor forward to `seq`.
    @discardableResult
    func moveReadCursor(_ id: ConversationID, of participant: ParticipantID, to seq: Seq) throws -> Bool {
        guard let state = conversations[id], seq > (state.summary.readCursors[participant] ?? 0),
              seq <= state.summary.lastSeq else { return false }
        let time = now()
        _ = try updateConversation(id) {
            $0.readCursors[participant] = seq
            $0.readCursorTimes[participant] = time
        }
        return true
    }

    /// Adds a new conversation to the inbox.
    func insertConversation(_ summary: ConversationSummary) throws {
        let state = ChiefConversationState(summary: summary)
        let log = ChiefConversationLog(url: Self.file(for: summary.id, in: home))
        do {
            try log.rewrite(state)
        } catch {
            let message = String(describing: error)
            lastPersistenceError = message
            throw PersistenceError(message: message)
        }
        conversations[summary.id] = state
        logs[summary.id] = log
        inboxRev += 1
        publish(.conversationChanged(summary, stream: .inbox, rev: inboxRev))
    }

    func persist(_ id: ConversationID, _ records: [ChiefLogRecord]) throws {
        guard let log = logs[id] else {
            let message = "missing log for \(id.rawValue)"
            lastPersistenceError = message
            throw PersistenceError(message: message)
        }
        do {
            try log.append(records)
        } catch {
            let message = String(describing: error)
            lastPersistenceError = message
            throw PersistenceError(message: message)
        }
    }

    static func mintMessageID() -> MessageID {
        MessageID("msg_" + mintSuffix(20))
    }

    static func mintSuffix(_ length: Int) -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(length))
    }
}
