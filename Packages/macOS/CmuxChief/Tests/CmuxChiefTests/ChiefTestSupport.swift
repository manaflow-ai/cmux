import CmuxChief
import CmuxHomeCore
import Foundation

/// What a fake brain was asked and told.
actor BrainLog {
    private(set) var requests: [ChiefTurnRequest] = []
    private(set) var terminations = 0
    private(set) var interrupts: [ConversationID] = []
    private(set) var approvals: [(id: String, choice: String)] = []
    private(set) var shutdowns = 0

    func started(_ request: ChiefTurnRequest) { requests.append(request) }
    func terminated() { terminations += 1 }
    func interrupted(_ conversation: ConversationID) { interrupts.append(conversation) }
    func approved(_ id: String, _ choice: String) { approvals.append((id, choice)) }
    func shutDown() { shutdowns += 1 }
}

/// A gate a script waits at until the test opens it.
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

/// A scripted ``ChiefBrain``: each turn runs `script` on its own task; the
/// stream's termination cancels that task and is logged.
final class FakeBrain: ChiefBrain {
    typealias Continuation = AsyncThrowingStream<ChiefTurnEvent, any Error>.Continuation
    typealias Script = @Sendable (ChiefTurnRequest, Continuation) async -> Void

    let log = BrainLog()
    let script: Script

    init(script: @escaping Script) {
        self.script = script
    }

    /// Replies with `chunks` as one text segment, then finishes.
    static func replying(_ chunks: [String], session: String? = nil) -> FakeBrain {
        FakeBrain { _, continuation in
            if let session { continuation.yield(.session(session)) }
            for chunk in chunks { continuation.yield(.textDelta(chunk)) }
            continuation.yield(.textSegmentEnd)
            continuation.yield(.finished)
            continuation.finish()
        }
    }

    /// Replies with each event in order, then finishes the stream.
    static func events(_ events: [ChiefTurnEvent]) -> FakeBrain {
        FakeBrain { _, continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func run(_ request: ChiefTurnRequest) -> AsyncThrowingStream<ChiefTurnEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<ChiefTurnEvent, any Error>.makeStream()
        let log = self.log
        let script = self.script
        let (started, starter) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in started { break }
            await log.started(request)
            await script(request, continuation)
        }
        continuation.onTermination = { _ in
            task.cancel()
            Task { await log.terminated() }
        }
        starter.yield()
        starter.finish()
        return stream
    }

    func respond(toApproval id: String, choice: String, conversation: ConversationID) async {
        await log.approved(id, choice)
    }

    func interrupt(conversation: ConversationID) async {
        await log.interrupted(conversation)
    }

    func shutdown() async {
        await log.shutDown()
    }
}

/// Every event one subscription saw, in order.
actor EventRecorder {
    private(set) var events: [HomeEvent] = []
    private var task: Task<Void, Never>?

    func record(_ event: HomeEvent) { events.append(event) }

    func start(_ owner: ChiefConversationOwner) async {
        let stream = await owner.events()
        task = Task { [weak self] in
            for await event in stream { await self?.record(event) }
        }
    }

    func messages() -> [Message] {
        events.compactMap {
            if case .message(let message, _) = $0 { return message }
            return nil
        }
    }

    func drafts() -> [HomeDraftUpdate] {
        events.compactMap {
            if case .draft(let update) = $0 { return update }
            return nil
        }
    }

    func stop() { task?.cancel() }
}

/// Test fixtures: a temp Chief home and an owner over it.
struct ChiefFixture {
    let home: ChiefHome
    let allowRules: ChiefAllowRules

    init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-chief-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        home = ChiefHome(root: root)
        allowRules = ChiefAllowRules()
    }

    func owner(_ brain: FakeBrain) throws -> ChiefConversationOwner {
        let home = self.home
        return try ChiefConversationOwner(home: home, brain: brain, userDisplayName: "Tester", allowRules: allowRules,
                                          now: { Date() }) { _ in
            ChiefTurnContext(systemPrompt: "You are Chief.", workingDirectory: home.root, environment: ["CHIEF": "1"])
        }
    }

    /// Polls `condition` every 5 ms until it holds or `timeout` passes.
    static func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Sends `text` as the user and returns the committed result.
    @discardableResult
    static func send(_ text: String, to owner: ChiefConversationOwner,
                     in conversation: ConversationID = ChiefConversationOwner.defaultConversationID,
                     threadRoot: MessageID? = nil, key: IdempotencyKey = .make()) async throws -> HomeOpResult {
        try await owner.submit(HomeIntent(key: key, op: .sendMessage(conversation: conversation, parts: [.text(text)],
                                                                      threadRoot: threadRoot)))
    }

    /// Waits until no turn runs and returns the conversation's messages.
    static func idleMessages(_ owner: ChiefConversationOwner,
                             in conversation: ConversationID = ChiefConversationOwner.defaultConversationID,
                             count: Int) async throws -> [Message] {
        _ = await eventually {
            let working = await owner.isWorking(conversation)
            let page = try? await owner.snapshot(of: conversation, tail: 100)
            return !working && (page?.messages.count ?? 0) >= count
        }
        return try await owner.snapshot(of: conversation, tail: 100).messages
    }
}
