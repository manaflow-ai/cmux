import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

/// The agent pane's data (user 2026-11-03, msg 19960): one agent's chat with the Chief from the run rows
/// (its task, later messages, how long it worked, the Chief's link to its workspace), and the pills' unread
/// dot, which clears once the person opens the agent and comes back with a newer report.
struct HomeAgentThreadTests {
    let chief = ParticipantID("agent_mux")
    let start = Date(timeIntervalSince1970: 1_000)

    func step(_ id: String, _ seq: UInt64, _ peer: String, out: Bool, _ text: String, at seconds: Double,
              sender: String? = nil) -> HomeAgentRun.Message {
        .init(id: id, sequence: seq, revision: 1, peer: peer, outgoing: out, text: text, date: start.addingTimeInterval(seconds),
              sender: sender)
    }

    func run(_ messages: [HomeAgentRun.Message], id: String = "run", answers: [MessageID] = [MessageID("question")]) -> HomeAgentRun {
        .init(conversation: ConversationID("c"), id: id, author: chief, turn: nil, answers: answers, revision: 1, messages: messages)
    }

    func item(_ id: String, author: ParticipantID, _ text: String, at seconds: Double = 0) -> TranscriptItem {
        .init(key: IdempotencyKey(id), seq: 1, author: author, parts: [.text(text)], createdAt: start.addingTimeInterval(seconds),
              delivery: .committed, messageID: MessageID(id))
    }

    @Test func anAgentsThreadIsItsTaskThenEveryLaterMessageAcrossRuns() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run([
            step("tell", 1, "a1", out: true, "Title: Fix the sidebar\n\nAlign the header.", at: 0),
            step("tell2", 2, "a2", out: true, "build the nightly", at: 1),
            step("report", 3, "a1", out: false, "Root cause found.", at: 120),
        ]))
        _ = book.apply(run([
            step("tell3", 1, "a1", out: true, "Also add a test.", at: 200),
            step("report2", 2, "a1", out: false, "Done: landed.", at: 335),
        ], id: "run2"))
        let items = [item("question", author: ParticipantID("me"), "fix it"),
                     item("reply", author: chief, "Started [a1](cmux://chief/0123abcd/session/s-81) and [a2](https://example.com).")]
        let thread = try #require(book.thread(peer: "a1", in: items))
        #expect(thread.title == "Fix the sidebar")
        #expect(thread.task == "Title: Fix the sidebar\n\nAlign the header.")
        #expect(thread.entries.map(\.text) == ["Root cause found.", "Also add a test.", "Done: landed."])
        #expect(thread.entries.map(\.outgoing) == [false, true, false])
        #expect(thread.state == .reported)
        #expect(thread.workedFor(now: start.addingTimeInterval(9_999)) == 335)
        #expect(thread.newestReportAt == start.addingTimeInterval(335))
        #expect(thread.workspaceLink == URL(string: "cmux://chief/0123abcd/session/s-81"))
        // a2 is still working: its time runs to now, and the Chief's only link for it is no session link.
        let working = try #require(book.thread(peer: "a2", in: items))
        #expect(working.state == .told && working.endedAt == nil && working.newestReportAt == nil)
        #expect(working.workedFor(now: start.addingTimeInterval(61)) == 60)
        #expect(working.workspaceLink == nil)
        #expect(book.thread(peer: "a9", in: items) == nil)
    }

    @Test func aStoppedAgentsThreadEndsWithItsNote() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run([
            step("tell", 1, "a1", out: true, "check the feed", at: 0),
            step("note", 2, "a1", out: false, "(stopped without a report: its session is Disconnected)", at: 72),
        ]))
        let thread = try #require(book.thread(peer: "a1", in: []))
        #expect(thread.state == .stopped && thread.workedFor(now: .distantFuture) == 72)
    }

    @Test(arguments: [
        ("[a1](cmux://chief/0123abcd/session/s-1)", "cmux://chief/0123abcd/session/s-1"),
        ("[a1](cmux://chief/0123ABCD/session/s-1)", nil),
        ("[a1](cmux://chief/0123abcd/session/s 1)", nil),
        ("[a12](cmux://chief/0123abcd/session/s-1)", nil),
        ("[a1](cmux://session/s-1)", nil),
        ("[a1](cmux://chief/0123abcd/session/old) then [a1](cmux://chief/0123abcd/session/new)", "cmux://chief/0123abcd/session/new"),
    ] as [(String, String?)])
    func theWorkspaceLinkIsOnlyTheChiefsSessionLinkForThatAgent(text: String, expected: String?) {
        #expect(HomeAgentThread.workspaceLink(for: "a1", in: [text]) == expected.flatMap(URL.init(string:)))
    }

    @Test func aReportedPillIsUnreadUntilSeenAndAgainAfterANewerReport() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run([
            step("tell", 1, "a1", out: true, "check", at: 0),
            step("tell2", 2, "a2", out: true, "build", at: 1),
            step("report", 3, "a1", out: false, "checked", at: 50),
        ]))
        let question = item("question", author: ParticipantID("me"), "go")
        func unread(_ seen: [String: Date]) -> [Bool]? {
            book.inserting(into: [question], summary: nil, seen: seen).last?.agentMessage?.peerUnread
        }
        #expect(unread([:]) == [true, false])
        #expect(unread(["a1": start.addingTimeInterval(50)]) == [false, false])
        _ = book.apply(run([step("report2", 4, "a1", out: false, "checked again", at: 90)]))
        #expect(unread(["a1": start.addingTimeInterval(50)]) == [true, false])
    }

    // MARK: Slice 3: the shared composer and its sender labels (user 2026-11-03, msgs 19960/19968)

    @Test func aNoteThePersonSentFromThePaneIsLabelledYouAndTheChiefsOwnMessagesChief() throws {
        let me = ParticipantID("me")
        var book = HomeAgentMessages()
        _ = book.apply(run([
            step("tell", 1, "a1", out: true, "Title: Fix the sidebar\n\nAlign the header.", at: 0),
            // The Chief relays the person's note word for word: one message, the person's.
            step("tell2", 2, "a1", out: true, "Use the 2x shot.", at: 40),
            step("tell3", 3, "a1", out: true, "Also run the lane.", at: 50),
            step("report", 4, "a1", out: false, "Done.", at: 90),
        ]))
        let items = [
            item("question", author: me, "fix the sidebar"),
            item("n1", author: me, HomeAgentNote(peer: "a1", text: "Use the 2x shot.").message, at: 30),
            // Not relayed yet: it shows as the person's at once.
            item("n2", author: me, HomeAgentNote(peer: "a1", text: "And the dark shot.").message, at: 95),
            item("n3", author: me, HomeAgentNote(peer: "a2", text: "Not for a1.").message, at: 96),
        ]
        let thread = try #require(book.thread(peer: "a1", in: items, me: me))
        #expect(thread.entries.map(\.text) == ["Use the 2x shot.", "Also run the lane.", "Done.", "And the dark shot."])
        #expect(thread.entries.map(\.sender) == [.you, .chief, .agent, .you])
        #expect(thread.entries.map(\.outgoing) == [true, true, false, true])
        // The task stays the Chief's "Sent via Chief" bubble.
        #expect(thread.task == "Title: Fix the sidebar\n\nAlign the header.")
    }

    @Test func thePromptsSenderMetaLabelsTheMessage() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run([
            step("tell", 1, "a1", out: true, "task", at: 0),
            step("tell2", 2, "a1", out: true, "from the person", at: 10, sender: "human:p_lawrence"),
            step("tell3", 3, "a1", out: true, "from the Chief", at: 20, sender: "chief:agent_mux"),
            step("tell4", 4, "a1", out: true, "no meta", at: 30),
            step("tell5", 5, "a1", out: true, "unknown meta", at: 40, sender: "robot"),
        ]))
        let thread = try #require(book.thread(peer: "a1", in: [], me: ParticipantID("me")))
        #expect(thread.entries.map(\.sender) == [.you, .chief, .chief, .chief])
    }

    @Test(arguments: [
        ("human:p_lawrence", HomeAgentSender.you),
        ("chief:agent_mux", HomeAgentSender.chief),
        ("human:", nil),
        ("chief", nil),
        ("", nil),
    ] as [(String, HomeAgentSender?)])
    func theSenderMetaNamesAPersonOrAChief(meta: String, expected: HomeAgentSender?) {
        #expect(HomeAgentSender(meta: meta) == expected)
    }

    @Test func aNoteIsItsAgentsIdThenTheWords() {
        let note = HomeAgentNote(peer: "a12", text: "Use the 2x shot.\nAnd the dark one.")
        #expect(note.message == "[to a12] Use the 2x shot.\nAnd the dark one.")
        #expect(HomeAgentNote(parsing: note.message) == note)
        #expect(HomeAgentNote(parsing: "[to a12]no space") == nil)
        #expect(HomeAgentNote(parsing: "[to ] empty id") == nil)
        #expect(HomeAgentNote(parsing: "[to a12] ") == nil)
        #expect(HomeAgentNote(parsing: "[a12] a report") == nil)
        #expect(HomeAgentNote(parsing: "please [to a12] x") == nil)
    }

    @MainActor @Test func aNoteFromThePaneGoesToTheChiefsChatSoTheChiefSeesIt() async throws {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        defer { store.stop() }
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        let conversation = ConversationID("conv_aziz")
        await store.open(conversation)
        let me = try #require(store.me?.id)
        try await store.sendAgentNote("  Use the 2x shot.  ", to: "a1", in: conversation)
        let sent = store.transcript(for: conversation).filter { $0.author == me && $0.plainText.hasPrefix("[to ") }
        #expect(sent.map(\.plainText) == ["[to a1] Use the 2x shot."])
        // Nothing to say: nothing goes.
        try await store.sendAgentNote(" \n ", to: "a1", in: conversation)
        #expect(store.transcript(for: conversation).filter { $0.author == me && $0.plainText.hasPrefix("[to ") }.count == 1)
    }

    // MARK: Slice 3 step 2: follow an agent by its session id (a963's spawn place and epoch, a964's moveEpoch)

    @Test func anAgentIsFollowedByItsSessionAndReattachesOnlyOnAHigherEpoch() throws {
        var ref = HomeAgentSessionRef(peer: "a1", session: "s-81")
        #expect(!ref.hasMoved)
        // A Chief move hands it to a mini (a963: place and a raised epoch in one spawn record write).
        let moved1 = ref.follow(HomeAgentSessionRef(peer: "a1", session: "s-81", place: "cmux-mini", spawnEpoch: 1))
        #expect(moved1)
        #expect(ref.place == "cmux-mini" && ref.spawnEpoch == 1 && ref.hasMoved)
        // An older or equal read never moves it back.
        let moved2 = ref.follow(HomeAgentSessionRef(peer: "a1", session: "s-81", place: nil, spawnEpoch: 1))
        #expect(!moved2)
        let moved3 = ref.follow(HomeAgentSessionRef(peer: "a1", session: "s-81", place: nil))
        #expect(!moved3)
        #expect(ref.place == "cmux-mini")
        // acpmux moves the session on (a964: transferred.to with a higher moveEpoch).
        let moved4 = ref.follow(HomeAgentSessionRef(peer: "a1", session: "s-81", place: "cloud", spawnEpoch: 1, moveEpoch: 1))
        #expect(moved4)
        #expect(ref.place == "cloud" && ref.moveEpoch == 1 && ref.spawnEpoch == 1)
        // Another session is another agent's chat: not followed.
        let moved5 = ref.follow(HomeAgentSessionRef(peer: "a1", session: "s-99", place: "elsewhere", moveEpoch: 9))
        #expect(!moved5)
        #expect(ref.place == "cloud")
        #expect(ref.sessionLink == URL(string: "cmux://session/s-81"))
    }

    @Test func theThreadNamesTheSessionOfTheChiefsLink() throws {
        var book = HomeAgentMessages()
        _ = book.apply(run([step("tell", 1, "a1", out: true, "task", at: 0)]))
        let linked = [item("reply", author: chief, "Started [a1](cmux://chief/0123abcd/session/s-81).")]
        #expect(try #require(book.thread(peer: "a1", in: linked)).session == "s-81")
        #expect(try #require(book.thread(peer: "a1", in: [])).session == nil)
    }

    @MainActor @Test func theStoreFollowsEachAgentsSessionAndAnOlderReadNeverMovesItBack() async throws {
        let source = MockHomeSource(options: .immediate)
        let store = HomeStore(source: source)
        store.start()
        defer { store.stop() }
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        let conversation = ConversationID("conv_aziz")
        await store.open(conversation)
        #expect(store.agentSession("a1", in: conversation) == nil)
        await source.setAgentSessions([HomeAgentSessionRef(peer: "a1", session: "s-81"), HomeAgentSessionRef(peer: "a2", session: "s-82")])
        #expect(await store.followAgentSessions(["a1", "a2"], in: conversation) == true)
        #expect(store.agentSession("a1", in: conversation)?.session == "s-81")
        #expect(store.agentSession("a1", in: conversation)?.hasMoved == false)
        let before = store.transcriptVersion[conversation, default: 0]
        await source.setAgentSessions([HomeAgentSessionRef(peer: "a1", session: "s-81", place: "cmux-mini", moveEpoch: 2)])
        #expect(await store.followAgentSessions(["a1", "a2"], in: conversation) == true)
        #expect(store.agentSession("a1", in: conversation)?.place == "cmux-mini")
        // The open agent tab redraws (it reads the transcript).
        #expect(store.transcriptVersion[conversation, default: 0] > before)
        // A read from before the move (a stale owner) leaves it where it went.
        await source.setAgentSessions([HomeAgentSessionRef(peer: "a1", session: "s-81", place: nil, moveEpoch: 1)])
        #expect(await store.followAgentSessions(["a1", "a2"], in: conversation) == false)
        #expect(store.agentSession("a1", in: conversation)?.place == "cmux-mini")
        // An agent the read no longer names keeps its last place.
        #expect(store.agentSession("a2", in: conversation)?.session == "s-82")
    }
}
