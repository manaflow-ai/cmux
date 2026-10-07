import Foundation
import Testing
@testable import CmuxConversationCore

@Suite struct ConversationPollModelTests {
    @Test func votesAreMultiSelectAndToggle() {
        var poll = ConversationPoll(question: "Lunch?", options: [
            ConversationPollOption(id: "a", text: "Tacos"),
            ConversationPollOption(id: "b", text: "Ramen"),
        ])
        poll.setVote(participantID: "me", optionID: "a", selected: true)
        poll.setVote(participantID: "me", optionID: "b", selected: true)
        poll.setVote(participantID: "me", optionID: "b", selected: true)
        #expect(poll.voteCount(for: "a") == 1)
        #expect(poll.voteCount(for: "b") == 1)
        poll.setVote(participantID: "me", optionID: "a", selected: false)
        #expect(!poll.hasVote(participantID: "me", optionID: "a"))
        #expect(poll.votes.count == 1)
    }

    @Test func barsScaleToTheLeaderAtTheWinnerFraction() {
        var poll = ConversationPoll(question: "", options: [
            ConversationPollOption(id: "a", text: "A"),
            ConversationPollOption(id: "b", text: "B"),
            ConversationPollOption(id: "c", text: "C"),
        ])
        #expect(poll.barFraction(for: "a") == 0)
        for voter in ["x", "y", "z", "w"] { poll.setVote(participantID: voter, optionID: "a", selected: true) }
        for voter in ["x", "y"] { poll.setVote(participantID: voter, optionID: "b", selected: true) }
        #expect(poll.barFraction(for: "a") == 0.95)
        #expect(poll.barFraction(for: "b") == 0.475)
        #expect(poll.barFraction(for: "c") == 0)
        #expect(poll.nonVoterIDs(among: ["me", "x", "q"]) == ["me", "q"])
    }
}

@MainActor
@Suite struct ConversationPollStoreTests {
    private func loaded(_ backend: PollBackend) async throws -> ConversationStore {
        let ids = ClientIDSequence(prefix: "poll")
        let store = ConversationStore(backend: backend, pageSize: 30, makeClientMessageID: { ids.next() })
        store.apply(.connected(info: backend.info, meID: "me", lagged: false))
        try await waitUntil { store.hasLoadedNewest }
        return store
    }

    @Test func sendPollIsOptimisticAndCarriesTheDraft() async throws {
        let backend = PollBackend()
        let store = try await loaded(backend)
        #expect(store.sendPoll(question: "Ship?", choices: ["Yes", " "]) == nil)
        let rowID = try #require(store.sendPoll(question: " Ship? ", choices: ["Yes", "", "No"]))
        let pending = try #require(store.message(rowID: rowID))
        #expect(pending.poll?.options.map(\.text) == ["Yes", "No"])
        #expect(pending.text == "Ship?")
        #expect(!store.canInteractWithPoll(pending))
        try await waitUntil { store.message(rowID: rowID)?.seq != nil }
        #expect(backend.sentPolls == [ConversationPollDraft(question: "Ship?", options: ["Yes", "No"])])
        #expect(store.message(rowID: rowID)?.poll?.options.map(\.id) == ["o1", "o2"])
    }

    @Test func trimNeverDropsAPollWithAnUnconfirmedVote() async throws {
        let backend = PollBackend()
        let store = try await loaded(backend)
        store.setViewing(true)
        for seq in 2...6 {
            store.apply(.message(ConversationMessage(id: "m\(seq)", seq: seq, clientMessageID: nil, senderID: "lc", sentAt: Date(), text: "\(seq)"), eventSeq: seq))
        }
        backend.holdVotes = true
        store.togglePollVote(messageID: "p1", optionID: "o1")
        #expect(!store.trimOlder(keepingNewest: 2))
        #expect(store.message(id: "p1") != nil)
        backend.releaseVotes()
        // Once the backend confirms the vote, the poll may go like any other row.
        try await waitUntil { store.trimOlder(keepingNewest: 2) }
        #expect(store.message(id: "p1") == nil)
    }

    @Test func voteAppliesAtOnceAndSurvivesARacingServerUpdate() async throws {
        let backend = PollBackend()
        let store = try await loaded(backend)
        backend.holdVotes = true
        store.togglePollVote(messageID: "p1", optionID: "o1")
        #expect(store.message(id: "p1")?.poll?.hasVote(participantID: "me", optionID: "o1") == true)
        // Another participant's vote lands before mine is confirmed; the
        // server copy does not have my vote yet, but the row must keep it.
        var other = backend.poll
        other.poll?.setVote(participantID: "lc", optionID: "o2", selected: true)
        store.apply(.message(other, eventSeq: 10))
        let poll = try #require(store.message(id: "p1")?.poll)
        #expect(poll.hasVote(participantID: "me", optionID: "o1"))
        #expect(poll.hasVote(participantID: "lc", optionID: "o2"))
        backend.releaseVotes()
        try await waitUntil { backend.voteCount == 1 }
        try await waitUntil { store.message(id: "p1")?.poll?.voteCount(for: "o1") == 2 }
        #expect(store.pollVoteFailure(messageID: "p1") == nil)
    }

    @Test func refusedVoteRollsBackToTheServerCopyAndRetries() async throws {
        let backend = PollBackend()
        let store = try await loaded(backend)
        backend.failNextVote = true
        store.togglePollVote(messageID: "p1", optionID: "o2")
        #expect(store.message(id: "p1")?.poll?.hasVote(participantID: "me", optionID: "o2") == true)
        try await waitUntil { store.pollVoteFailure(messageID: "p1") != nil }
        #expect(store.pollVoteFailure(messageID: "p1") == ConversationPollVoteFailure(optionID: "o2", selected: true))
        #expect(store.message(id: "p1")?.poll?.hasVote(participantID: "me", optionID: "o2") == false)
        // Other voters stay as the server last reported them.
        #expect(store.message(id: "p1")?.poll?.hasVote(participantID: "aw", optionID: "o1") == true)

        store.retryPollVote(messageID: "p1")
        #expect(store.pollVoteFailure(messageID: "p1") == nil)
        try await waitUntil { backend.voteCount == 2 }
        try await waitUntil { store.message(id: "p1")?.poll?.hasVote(participantID: "me", optionID: "o2") == true }
        #expect(backend.votes.last?.selected == true)
    }

    @Test func tappingAVotedChoiceTakesTheVoteBack() async throws {
        let backend = PollBackend()
        let store = try await loaded(backend)
        store.togglePollVote(messageID: "p1", optionID: "o1")
        try await waitUntil { backend.voteCount == 1 }
        store.togglePollVote(messageID: "p1", optionID: "o1")
        try await waitUntil { backend.voteCount == 2 }
        #expect(backend.votes.map(\.selected) == [true, false])
        try await waitUntil { store.message(id: "p1")?.poll?.hasVote(participantID: "me", optionID: "o1") == false }
    }

    @Test func addedChoiceShowsAtOnceWithoutDuplicatingTheServerEcho() async throws {
        let backend = PollBackend()
        let store = try await loaded(backend)
        backend.holdVotes = true
        store.addPollChoice(messageID: "p1", text: "Sushi")
        #expect(store.message(id: "p1")?.poll?.options.map(\.text) == ["Tacos", "Ramen", "Sushi"])
        var echo = backend.poll
        echo.poll?.options.append(ConversationPollOption(id: "o3", text: "Sushi", addedByID: "me"))
        store.apply(.message(echo, eventSeq: 11))
        #expect(store.message(id: "p1")?.poll?.options.map(\.text) == ["Tacos", "Ramen", "Sushi"])
        backend.releaseVotes()
        try await waitUntil { store.message(id: "p1")?.poll?.options.last?.id == "o3" }
        #expect(store.message(id: "p1")?.poll?.options.count == 3)
    }

    @Test func refusedChoiceIsRemoved() async throws {
        let backend = PollBackend()
        let store = try await loaded(backend)
        backend.failNextVote = true
        store.addPollChoice(messageID: "p1", text: "Pizza")
        #expect(store.message(id: "p1")?.poll?.options.count == 3)
        try await waitUntil { store.message(id: "p1")?.poll?.options.count == 2 }
    }
}

/// One conversation with a poll `p1` (Tacos/Ramen; aw voted Tacos).
final class PollBackend: ConversationBackend, @unchecked Sendable {
    let info = ConversationInfo(id: "g", title: "cmux", kind: .group, participants: [
        ConversationParticipant(id: "me", name: "Me", initials: "ME", colorHex: "#0A84FF", isMe: true),
        ConversationParticipant(id: "lc", name: "Lawrence Chen", initials: "LC", colorHex: "#30B0C7", isMe: false),
        ConversationParticipant(id: "aw", name: "Austin Wang", initials: "AW", colorHex: "#8E8E93", isMe: false),
    ])
    private let lock = NSLock()
    private var _poll: ConversationMessage
    private var _hold = false
    private var _waiters: [CheckedContinuation<Void, Never>] = []
    private var _failNext = false
    private var _votes: [(optionID: String, selected: Bool)] = []
    private var _sentPolls: [ConversationPollDraft] = []

    init() {
        _poll = ConversationMessage(
            id: "p1", seq: 1, clientMessageID: nil, senderID: "lc", sentAt: Date(), text: "Lunch?",
            poll: ConversationPoll(
                question: "Lunch?",
                options: [ConversationPollOption(id: "o1", text: "Tacos"), ConversationPollOption(id: "o2", text: "Ramen")],
                votes: [ConversationPollVote(participantID: "aw", optionID: "o1")]
            )
        )
    }

    var poll: ConversationMessage { lock.withLock { _poll } }
    var holdVotes: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }
    var failNextVote: Bool {
        get { lock.withLock { _failNext } }
        set { lock.withLock { _failNext = newValue } }
    }
    var votes: [(optionID: String, selected: Bool)] { lock.withLock { _votes } }
    var voteCount: Int { votes.count }
    var sentPolls: [ConversationPollDraft] { lock.withLock { _sentPolls } }

    func releaseVotes() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _hold = false
            defer { _waiters = [] }
            return _waiters
        }
        waiters.forEach { $0.resume() }
    }

    private func gate() async throws {
        await withCheckedContinuation { waiter in
            let now = lock.withLock { () -> Bool in
                guard _hold else { return true }
                _waiters.append(waiter)
                return false
            }
            if now { waiter.resume() }
        }
        let fail = lock.withLock { () -> Bool in
            defer { _failNext = false }
            return _failNext
        }
        if fail { throw ConversationBackendError(code: -32004, message: "vote not delivered") }
    }

    func votePoll(messageID: String, optionID: String, selected: Bool) async throws -> ConversationMessage {
        defer { lock.withLock { _votes.append((optionID, selected)) } }
        try await gate()
        return lock.withLock {
            _poll.poll?.setVote(participantID: "me", optionID: optionID, selected: selected)
            return _poll
        }
    }

    func addPollOption(messageID: String, text: String) async throws -> ConversationMessage {
        try await gate()
        return lock.withLock {
            let id = "o\((_poll.poll?.options.count ?? 0) + 1)"
            _poll.poll?.options.append(ConversationPollOption(id: id, text: text, addedByID: "me"))
            return _poll
        }
    }

    func events() -> AsyncStream<ConversationBackendEvent> { AsyncStream { _ in } }
    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage {
        ConversationHistoryPage(messages: beforeSeq == nil ? [poll] : [], hasMore: false)
    }
    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        lock.withLock { if let poll = draft.poll { _sentPolls.append(poll) } }
        return ConversationMessage(
            id: "m2", seq: 2, clientMessageID: draft.clientMessageID, senderID: "me", sentAt: Date(), text: draft.text,
            delivery: .sent,
            poll: draft.poll.map { draft in
                ConversationPoll(question: draft.question, options: draft.options.enumerated().map {
                    ConversationPollOption(id: "o\($0.offset + 1)", text: $0.element)
                })
            }
        )
    }
    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage { poll }
    func edit(messageID: String, text: String) async throws -> ConversationMessage { poll }
    func unsend(messageID: String) async throws -> ConversationMessage { poll }
    func setTyping(_ isTyping: Bool) async {}
    func markRead(upToSeq: Int) async {}
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment {
        ConversationAttachment(id: "up", kind: .image, width: 1, height: 1, url: nil)
    }
    func close() {}
}
