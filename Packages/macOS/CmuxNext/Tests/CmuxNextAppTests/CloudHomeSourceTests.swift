import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Synchronization
import Testing
@testable import CmuxNextApp

/// The cloud Home source over the daemon proxy (home-cloud-proxy.md, part 2):
/// it reads and writes only through `cloud-conversations-v1`, keeps the
/// owners' ids, and shows the signed-in account as the store's one `me`.
@Suite(.timeLimit(.minutes(1))) nonisolated struct CloudHomeSourceTests {
    typealias F = CloudFixtures
    let dm = "conv_dm_01J0000000000000000000000A"

    func configured(_ script: FakeCloudDaemon.Script) async -> (CloudHomeSource, FakeCloudDaemon, EventTape) {
        let daemon = FakeCloudDaemon(script)
        let source = CloudHomeSource(me: Participant(id: F.localMe, kind: .human, displayName: "Me"))
        let tape = await EventTape(source)
        source.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: F.identity)
        return (source, daemon, tape)
    }

    func summaries(_ events: [HomeEvent], _ id: String) -> [CmuxHomeCore.ConversationSummary] {
        events.compactMap { event in
            switch event {
            case .conversationChanged(let summary, _, _) where summary.id.rawValue == id: summary
            case .inbox(let inbox): inbox.conversations.first { $0.id.rawValue == id }
            default: nil
            }
        }
    }

    @Test func theInboxJoinsEachEntryWithItsHeadAndShowsTheAccountAsMe() async throws {
        let (source, daemon, tape) = await configured(.init(entries: [F.entry(dm, pinned: true)], heads: [dm: F.head(dm)]))
        defer { withExtendedLifetime(source) {} }
        // The inbox lists, then a one-message snapshot names the participants.
        #expect(await tape.wait { summaries($0, dm).contains { $0.participants.contains { $0.displayName == "Bob" } } })
        let summary = try #require(summaries(tape.all, dm).last)
        #expect(summary.owner == .cloud)
        #expect(summary.pinRank == 0)
        #expect(summary.participants.map(\.id) == [F.localMe, ParticipantID("user_bob")])
        #expect(summary.kind(me: F.localMe) == .direct)
        #expect(summary.readCursors[F.localMe] == 1)
        #expect(summary.lastMessage?.author == ParticipantID("user_bob"))
        #expect(daemon.calls.prefix(2) == [.subscribeInbox, .inboxList])
        #expect(daemon.calls.contains(.snapshot(dm, tail: 1)))
    }

    @Test func openingSubscribesBeforeReadingAndClampsTheTail() async throws {
        let messages = (1...3).map { F.message(dm, seq: $0, author: $0 == 2 ? "user_stack-me" : "user_bob") }
        let (source, daemon, _) = await configured(.init(heads: [dm: F.head(dm, lastSeq: 3)], messages: [dm: messages]))
        let page = try await source.snapshot(of: ConversationID(dm), tail: 60)
        let reads = daemon.calls.filter { if case .subscribeInbox = $0 { false } else if case .inboxList = $0 { false } else { true } }
        #expect(reads == [.subscribe(dm), .snapshot(dm, tail: 50)])
        #expect(page.messages.map(\.seq) == [1, 2, 3])
        #expect(page.messages[1].author == F.localMe)
        #expect(page.conversation.owner == .cloud)
    }

    @Test func aSendKeepsTheKeyAsItsClientIDAndNamesTheAccountByItsCloudID() async throws {
        let (source, daemon, _) = await configured(.init(heads: [dm: F.head(dm)]))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        let key = IdempotencyKey("cmk_send")
        let parts: [MessagePart] = [.text("me and bob", mentions: [Mention(start: 0, length: 2, participant: F.localMe),
                                                                   Mention(start: 7, length: 3, participant: ParticipantID("user_bob"))])]
        let result = try await source.submit(HomeIntent(key: key, op: .sendMessage(conversation: ConversationID(dm), parts: parts)))
        #expect(result.rev == 2)
        #expect(result.conversation == ConversationID(dm))
        let request = try #require(daemon.opRequests.last)
        #expect(request.conversation == dm)
        #expect(request.idempotencyKey == "cmk_send")
        #expect(request.origin == "user")
        #expect(request.op == .send(clientMsgID: "cmk_send",
                                    parts: [.text("me and bob", runs: [ConversationTextRun(start: 0, length: 2, mention: "user_stack-me"),
                                                                       ConversationTextRun(start: 7, length: 3, mention: "user_bob")])],
                                    replyTo: nil))
    }

    /// A disconnected socket is a short outage: the edit stays pending (the
    /// store resends it after recovery) instead of failing as Not Delivered.
    @Test func editsWaitWhileTheConversationSocketIsDisconnected() async throws {
        let (source, daemon, _) = await configured(.init(heads: [dm: F.head(dm)], subscribeState: "disconnected"))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        let send = HomeIntent(key: IdempotencyKey("cmk_x"), op: .sendMessage(conversation: ConversationID(dm), parts: [.text("x")]))
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.submit(send) }
        #expect(daemon.opRequests.isEmpty)
        source.handle(.subscriptionState(CloudSubscriptionState(scope: "conversation", conversation: dm, state: "live")))
        _ = try await source.submit(send)
        #expect(daemon.opRequests.count == 1)
    }

    /// An op refused for an expired token waits; the renewed lease tells the
    /// store to resend it, once per failure.
    @Test func aRenewedLeaseAfterARefusedOpTellsTheStoreToResend() async throws {
        let (source, _, tape) = await configured(.init(heads: [dm: F.head(dm)], op: { _ in
            throw DaemonError.command(cmd: "cloud-conversation-op", message: "expired", code: "cloud_session_expired",
                                      details: .object(["reason": .string("expired")]), retryable: true)
        }))
        @Sendable func recoveries(_ events: [HomeEvent]) -> Int { events.filter { $0 == .ownerRecovered }.count }
        #expect(await tape.wait { $0.contains { if case .inbox = $0 { true } else { false } } })
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        let before = recoveries(tape.all)
        let send = HomeIntent(key: IdempotencyKey("cmk_l"), op: .sendMessage(conversation: ConversationID(dm), parts: [.text("x")]))
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.submit(send) }
        source.leaseRenewed(subject: "stack-me")
        #expect(await tape.wait { recoveries($0) == before + 1 })
        // Nothing failed since: a second renewal is not a recovery.
        source.leaseRenewed(subject: "stack-me")
        source.handle(.inboxChanged(CloudInboxChanged(seq: 4, entries: [F.entry(dm)], account: "stack-me")))
        #expect(await tape.wait { !summaries($0, dm).isEmpty })
        #expect(recoveries(tape.all) == before + 1)
    }

    @Test func ownerEventsBecomeHomeEventsWithTheOwnersRevisions() async throws {
        let (source, _, tape) = await configured(.init(heads: [dm: F.head(dm)]))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        source.handle(.changed(CloudConversationChanged(conversation: dm, rev: 4, seq: 9,
                                                        change: .message(F.message(dm, seq: 2, author: "user_stack-me")), account: "stack-me")))
        source.handle(.changed(CloudConversationChanged(conversation: dm, rev: 5, seq: 10,
                                                        change: .readCursor(participant: "user_bob", seq: 2), account: "stack-me")))
        source.handle(.changed(CloudConversationChanged(conversation: dm, rev: 6, seq: 11, change: .unknown(kind: "invite"), account: "stack-me")))
        source.handle(.resynced(CloudConversationResynced(conversation: dm, rev: 6, seq: 11, summary: F.head(dm, rev: 6, lastSeq: 2),
                                                          messages: [F.message(dm, seq: 1), F.message(dm, seq: 2)], account: "stack-me")))
        #expect(await tape.wait { $0.contains { if case .conversationPage = $0 { true } else { false } } })
        let conversationEvents = tape.all.filter {
            switch $0 {
            case .message, .conversationPage: true
            case .conversationChanged(_, stream: .conversation, rev: _): true
            default: false
            }
        }
        guard conversationEvents.count == 4,
              case .message(let message, rev: 4) = conversationEvents[0],
              case .conversationChanged(let cursor, stream: .conversation(let stream), rev: 5) = conversationEvents[1],
              case .conversationChanged(_, stream: .conversation, rev: 6) = conversationEvents[2],
              case .conversationPage(let page) = conversationEvents[3] else {
            Issue.record("events \(conversationEvents)")
            return
        }
        #expect(message.author == F.localMe)
        #expect(stream == ConversationID(dm))
        #expect(cursor.readCursors[ParticipantID("user_bob")] == 2)
        #expect(cursor.lastSeq == 2)
        #expect(page.conversation.rev == 6)
        #expect(page.messages.map(\.seq) == [1, 2])
    }

    @Test func startingAConversationOpensTheDMThenSendsTheFirstMessageWithADerivedKey() async throws {
        let opened = "conv_dm_01J0000000000000000000000B"
        let (source, daemon, tape) = await configured(.init(op: { request in
            switch request.op {
            case .dmOpen: return CloudConversationOpResult(conversation: F.head(opened, rev: 1, lastSeq: 0,
                                                                                participants: [F.participant("user_stack-me", "Me"),
                                                                                               F.participant("addr_X", "b***@x.co", kind: .address)]),
                                                           invite: .init(ok: true))
            default: return CloudConversationOpResult(rev: 2, seq: 1)
            }
        }))
        let result = try await source.submit(HomeIntent(key: IdempotencyKey("cmk_start"),
                                                        op: .startConversation(contacts: [.email("bob@x.co")], firstMessage: [.text("hey")])))
        #expect(result.conversation == ConversationID(opened))
        #expect(result.invite == InviteReceipt(contact: .email("bob@x.co"), channel: .email, alreadyMember: false))
        let ops = daemon.calls.filter { if case .op = $0 { true } else { false } }
        #expect(ops == [.op(conversation: nil, key: "cmk_start", kind: "dm.open"),
                        .op(conversation: opened, key: "cmk_start:message", kind: "message.send")])
        #expect(daemon.opRequests.first?.op == .dmOpen(peer: .address(.email("bob@x.co"))))
        #expect(daemon.opRequests.last?.op == .send(clientMsgID: "cmk_start:message", parts: [.text("hey", runs: [])], replyTo: nil))
        // The new conversation shows at once, its address as an invited person.
        #expect(await tape.wait { summaries($0, opened).contains { $0.hasInvitedParticipant } })
    }

    @Test func aGroupStartsWithTheAccountAndTheParticipantsItKnows() async throws {
        let group = "conv_01J0000000000000000000000C"
        let (source, daemon, _) = await configured(.init(heads: [dm: F.head(dm)], op: { _ in
            CloudConversationOpResult(conversation: F.head(group, rev: 1, lastSeq: 0, kind: "group"))
        }))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        let result = try await source.submit(HomeIntent(key: IdempotencyKey("cmk_g"),
                                                        op: .createGroup(title: "Plan", participants: [F.localMe, ParticipantID("user_bob")])))
        #expect(result.conversation == ConversationID(group))
        #expect(daemon.opRequests.last?.conversation == nil)
        #expect(daemon.opRequests.last?.op == .create(title: "Plan", participants: [F.participant("user_stack-me", "Me"),
                                                                                    F.participant("user_bob", "Bob")]))
    }

    @Test func pinAndMuteAreRefusedWithoutReachingTheDaemon() async {
        let (source, daemon, _) = await configured(.init())
        await #expect(throws: HomeRejection.invalid("unsupported_op")) {
            try await source.submit(HomeIntent(op: .setPinned(conversation: ConversationID(dm), rank: 0)))
        }
        await #expect(throws: HomeRejection.invalid("unsupported_op")) {
            try await source.submit(HomeIntent(op: .setMuted(conversation: ConversationID(dm), muted: true)))
        }
        #expect(daemon.opRequests.isEmpty)
    }

    @Test func daemonErrorsBecomeHomeRejections() {
        func reject(_ code: String?, _ reason: String? = nil, retryable: Bool? = nil) -> HomeRejection {
            CloudHomeSource.rejection(.command(cmd: "cloud-conversation-op", message: "m", code: code,
                                               details: reason.map { .object(["reason": .string($0)]) }, retryable: retryable))
        }
        #expect(reject("cloud_conversation_rejected", "not_reachable", retryable: false) == .invalid("not_reachable"))
        #expect(reject("cloud_conversation_rejected", "forbidden", retryable: false) == .notAuthorized)
        #expect(reject("cloud_conversation_rejected", "agent_rate", retryable: true) == .rateLimited(retryAfter: nil))
        // No lease: nothing was sent, so it waits for one (not a final refusal).
        #expect(reject("cloud_signed_out", "missing") == .ownerUnreachable)
        #expect(reject("cloud_unauthenticated", "unauthenticated", retryable: true) == .ownerUnreachable)
        #expect(reject("cloud_unavailable", "unavailable", retryable: true) == .indeterminate)
        #expect(reject(nil) == .invalid("m"))
        #expect(CloudHomeSource.rejection(.notConnected) == .ownerUnreachable)
        #expect(CloudHomeSource.rejection(.timedOut("op")) == .indeterminate)
    }

    @Test func signingOutEmptiesTheCloudInbox() async throws {
        let (source, daemon, tape) = await configured(.init(entries: [F.entry(dm)], heads: [dm: F.head(dm)]))
        #expect(await tape.wait { !summaries($0, dm).isEmpty })
        source.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: nil)
        #expect(await tape.wait { events in
            guard case .inbox(let inbox)? = events.last(where: { if case .inbox = $0 { true } else { false } }) else { return false }
            return inbox.conversations.isEmpty
        })
        await #expect(throws: HomeRejection.notAuthorized) {
            try await source.submit(HomeIntent(op: .sendMessage(conversation: ConversationID(dm), parts: [.text("x")])))
        }
    }

    @Test func addressesAreMaskedLikeTheWorker() {
        #expect(CloudHomeSource.masked(.email("bob@x.co")) == "b***@x.co")
        #expect(CloudHomeSource.masked(.phone("+14155550100")) == "+1 *** *** 0100")
        #expect(CloudHomeSource.masked(.phone("+447700900123")) == "+44 *** *** 0123")
        // Too short, or not E.164: nothing of the number shows.
        #expect(CloudHomeSource.masked(.phone("+1234567")) == "***")
        #expect(CloudHomeSource.masked(.phone("+12345678")) == "***")
        #expect(CloudHomeSource.masked(.phone("4155550100")) == "***")
        #expect(CloudHomeSource.masked(.phone("+1415555010x")) == "***")
    }

    /// A page read for account A that finishes after sign-out or an account
    /// switch must not reach the store: it would put A's conversation back.
    @Test func aReadForThePreviousAccountNeverReturnsItsPage() async throws {
        let snapshotGate = Gate()
        let historyGate = Gate()
        let messages = (1...3).map { F.message(dm, seq: $0) }
        let (source, daemon, _) = await configured(.init(heads: [dm: F.head(dm, lastSeq: 3)], messages: [dm: messages],
                                                         snapshotGate: snapshotGate, historyGate: historyGate))
        let read = Task { try await source.snapshot(of: ConversationID(dm), tail: 10) }
        await snapshotGate.arrived()
        source.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: nil)
        snapshotGate.open()
        await #expect(throws: HomeRejection.notAuthorized) { try await read.value }
        #expect(source.currentInbox().conversations.isEmpty)

        source.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: F.identity)
        let older = Task { try await source.history(of: ConversationID(dm), before: 3, limit: 10) }
        await historyGate.arrived()
        let other = CloudIdentity(stackUserID: "stack-other", displayName: "Other", localID: F.localMe)
        source.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: other)
        historyGate.open()
        await #expect(throws: HomeRejection.notAuthorized) { try await older.value }
    }

    /// Intents belong to the account that made them. Account A's start of a
    /// conversation got no answer; after a switch to account B the same
    /// intent (a store resend) never reaches the owner, while B's own do.
    @Test func anAccountSwitchNeverSendsThePreviousAccountsUnconfirmedIntent() async throws {
        let opened = "conv_dm_01J0000000000000000000000B"
        let (source, daemon, tape) = await configured(.init(op: { _ in throw F.unavailable() }))
        let start = HomeIntent(key: IdempotencyKey("cmk_a"),
                               op: .startConversation(contacts: [.email("x@y.com")], firstMessage: [.text("hello")]))
        #expect(await signedIn(tape))
        await #expect(throws: HomeRejection.indeterminate) { try await source.submit(start) }
        daemon.script.withLock { $0.op = { _ in CloudConversationOpResult(conversation: F.head(opened, rev: 1, lastSeq: 0)) } }
        let before = daemon.opRequests.count
        let mark = tape.all.count
        let other = CloudIdentity(stackUserID: "stack-other", displayName: "Other", localID: F.localMe)
        source.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: other)
        // The store is told to drop it first: before the emptied inbox and any
        // event or reply of the new account (one that recovers the store).
        #expect(await tape.wait { $0.count > mark })
        #expect(tape.all[mark] == .intentsRevoked([start.key]), "\(tape.all[mark...])")
        await #expect(throws: HomeRejection.notAuthorized) { try await source.submit(start) }
        #expect(daemon.opRequests.count == before)
        _ = try await source.submit(HomeIntent(key: IdempotencyKey("cmk_b"), op: .invite(contact: .email("z@y.com"))))
        #expect(daemon.opRequests.dropFirst(before).map(\.idempotencyKey) == ["cmk_b"])
    }

    /// A new display name is the same account: nothing it sent is refused.
    @Test func aNewDisplayNameIsNotAnAccountChange() async throws {
        let (source, daemon, tape) = await configured(.init(heads: [dm: F.head(dm)], op: { _ in throw F.unavailable() }))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        let send = HomeIntent(key: IdempotencyKey("cmk_n"), op: .sendMessage(conversation: ConversationID(dm), parts: [.text("x")]))
        await #expect(throws: HomeRejection.indeterminate) { try await source.submit(send) }
        daemon.script.withLock { $0.op = { _ in CloudConversationOpResult(rev: 4) } }
        let renamed = CloudIdentity(stackUserID: "stack-me", displayName: "Me Renamed", localID: F.localMe)
        source.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: renamed)
        #expect(try await source.submit(send).rev == 4)
        #expect(!tape.all.contains { if case .intentsRevoked = $0 { true } else { false } })
    }

    /// An archived conversation stays out of the inbox when its stream moves
    /// later (UserDO owns membership of the inbox, not the conversation stream).
    @Test func anArchivedConversationStaysOutWhenItsStreamMovesLater() async throws {
        let other = "conv_dm_01J0000000000000000000000D"
        let (source, daemon, tape) = await configured(.init(entries: [F.entry(dm)], heads: [dm: F.head(dm), other: F.head(other)]))
        #expect(await tape.wait { events in
            events.contains { if case .inbox(let inbox) = $0 { inbox.conversations.contains { $0.id.rawValue == dm } } else { false } }
        })
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        source.handle(.inboxChanged(CloudInboxChanged(seq: 5, entries: [F.entry(dm, archived: true)], account: "stack-me")))
        source.handle(.changed(CloudConversationChanged(conversation: dm, rev: 4, seq: 9, change: .readCursor(participant: "user_bob", seq: 1), account: "stack-me")))
        source.handle(.changed(CloudConversationChanged(conversation: dm, rev: 5, seq: 10, change: .conversation(F.head(dm, rev: 5)), account: "stack-me")))
        source.handle(.resynced(CloudConversationResynced(conversation: dm, rev: 6, seq: 11, summary: F.head(dm, rev: 6),
                                                          messages: [F.message(dm, seq: 1)], account: "stack-me")))
        source.handle(.inboxChanged(CloudInboxChanged(seq: 6, entries: [F.entry(other)], account: "stack-me")))
        #expect(await tape.wait { !summaries($0, other).isEmpty })
        var mirror = HomeMirror()
        for event in tape.all { mirror.apply(event) }
        #expect(mirror.conversations[ConversationID(dm)] == nil)
        #expect(mirror.conversations[ConversationID(other)] != nil)
        #expect(await daemon.wait { $0.contains(.unsubscribe(dm)) })
    }

    /// A conversation this source just created stays in the inbox until its
    /// UserDO entry arrives, so a reload in between does not hide it.
    @Test func aConversationJustOpenedStaysListedUntilItsInboxEntryArrives() async throws {
        let opened = "conv_dm_01J0000000000000000000000B"
        let (source, _, tape) = await configured(.init(op: { _ in
            CloudConversationOpResult(conversation: F.head(opened, rev: 1, lastSeq: 0))
        }))
        @Sendable func inboxes(_ events: [HomeEvent]) -> [InboxSnapshot] {
            events.compactMap { if case .inbox(let inbox) = $0 { inbox } else { nil } }
        }
        // Signing in publishes the empty inbox, then the listed one.
        #expect(await tape.wait { inboxes($0).count >= 2 })
        _ = try await source.submit(HomeIntent(key: IdempotencyKey("cmk_o"), op: .invite(contact: .email("bob@x.co"))))
        #expect(source.currentInbox().conversations.contains { $0.id.rawValue == opened })
        let before = inboxes(tape.all).count
        source.handle(.inboxReset(seq: 7))
        #expect(await tape.wait { inboxes($0).count > before })
        #expect(inboxes(tape.all).last?.conversations.contains { $0.id.rawValue == opened } == true)
        // Its entry arrives, then UserDO archives it: it leaves.
        source.handle(.inboxChanged(CloudInboxChanged(seq: 8, entries: [F.entry(opened, rev: 1, lastSeq: 0)], account: "stack-me")))
        source.handle(.inboxChanged(CloudInboxChanged(seq: 9, entries: [F.entry(opened, rev: 2, lastSeq: 0, archived: true)], account: "stack-me")))
        #expect(!source.currentInbox().conversations.contains { $0.id.rawValue == opened })
    }

    func inboxCount(_ events: ArraySlice<HomeEvent>) -> Int {
        events.filter { if case .inbox = $0 { true } else { false } }.count
    }

    /// Signing in publishes the emptied inbox, then the listed one.
    func signedIn(_ tape: EventTape) async -> Bool {
        await tape.wait { inboxCount($0[...]) >= 2 }
    }

    static let other = CloudIdentity(stackUserID: "stack-other", displayName: "Other", localID: CloudFixtures.localMe)

    /// A stream event of account A's conversation that arrives after the
    /// switch to B (before the daemon processed A's unsubscribe, or from a
    /// socket the daemon reopened) never lists A's conversation for B.
    @Test func aLateStreamEventOfThePreviousAccountNeverEntersTheNextInbox() async throws {
        let theirs = "conv_dm_01J0000000000000000000000F"
        let (source, daemon, tape) = await configured(.init(heads: [dm: F.head(dm)]))
        #expect(await signedIn(tape))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        let mark = tape.all.count
        source.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: Self.other)
        #expect(await tape.wait { inboxCount($0[mark...]) >= 2 })
        source.handle(.changed(CloudConversationChanged(conversation: dm, rev: 5, seq: 9, change: .conversation(F.head(dm, rev: 5)), account: "stack-other")))
        source.handle(.changed(CloudConversationChanged(conversation: dm, rev: 6, seq: 10, change: .message(F.message(dm, seq: 2)), account: "stack-other")))
        source.handle(.resynced(CloudConversationResynced(conversation: dm, rev: 7, seq: 11, summary: F.head(dm, rev: 7, lastSeq: 2),
                                                          messages: [F.message(dm, seq: 1), F.message(dm, seq: 2)], account: "stack-other")))
        // B's own inbox event still lists B's conversation.
        source.handle(.inboxChanged(CloudInboxChanged(seq: 1, entries: [F.entry(theirs)], account: "stack-other")))
        #expect(await tape.wait { !summaries($0, theirs).isEmpty })
        var mirror = HomeMirror()
        for event in tape.all { mirror.apply(event) }
        #expect(mirror.conversations[ConversationID(dm)] == nil, "A's conversation listed for B")
        #expect(mirror.conversations[ConversationID(theirs)] != nil)
    }

    /// One queue serves the whole source: at most `hydrationWidth` reads at
    /// once, however many listed conversations lack a head.
    @Test func hydrationReadsAtMostFourConversationsAtOnce() async throws {
        let ids = (0..<10).map { "conv_dm_01J00000000000000000000\(10 + $0)" }
        let gate = Gate()
        let (source, daemon, _) = await configured(.init(entries: ids.map { F.entry($0) },
                                                         heads: Dictionary(uniqueKeysWithValues: ids.map { ($0, F.head($0)) }),
                                                         snapshotGate: gate))
        defer { withExtendedLifetime(source) {} }
        @Sendable func reads(_ calls: [FakeCloudDaemon.Call]) -> Int { calls.filter { if case .snapshot = $0 { true } else { false } }.count }
        #expect(await daemon.wait { reads($0) >= CloudHomeSource.hydrationWidth })
        gate.open()
        #expect(await daemon.wait { reads($0) == ids.count })
        #expect(daemon.maxSnapshotsInFlight == CloudHomeSource.hydrationWidth)
    }

    /// A listed conversation reads its head only when it has none or the
    /// entry's newest message is past it; pin, mute and unread come from
    /// the entry and read nothing.
    @Test func hydrationReadsOnlyAMissingOrBehindHead() async throws {
        let (source, daemon, tape) = await configured(.init(entries: [F.entry(dm)], heads: [dm: F.head(dm)]))
        @Sendable func reads(_ calls: [FakeCloudDaemon.Call]) -> Int { calls.filter { $0 == .snapshot(dm, tail: 1) }.count }
        #expect(await tape.wait { summaries($0, dm).contains { $0.participants.contains { $0.displayName == "Bob" } } })
        #expect(reads(daemon.calls) == 1)
        daemon.script.withLock { $0.entries = [F.entry(dm, pinned: true)] }
        _ = try await source.inbox()
        #expect(source.queuedHydrations == 0)
        #expect(reads(daemon.calls) == 1)
        daemon.script.withLock { script in
            script.entries = [F.entry(dm, rev: 4, lastSeq: 2)]
            script.heads[dm] = F.head(dm, rev: 4, lastSeq: 2)
        }
        _ = try await source.inbox()
        #expect(await daemon.wait { reads($0) == 2 })
        #expect(await tape.wait { summaries($0, dm).contains { $0.lastSeq == 2 } })
    }

    /// Typing is never sent, and an op the owner refused for good is never
    /// resent: neither stays bound to the account, so a later switch does
    /// not carry them in its revocation (which would grow without bound).
    @Test func typingAndRefusedOpsAreNotHeldForRevocation() async throws {
        let (source, daemon, tape) = await configured(.init())
        #expect(await signedIn(tape))
        await #expect(throws: HomeRejection.invalid("unsupported_op")) {
            try await source.submit(HomeIntent(key: IdempotencyKey("cmk_pin"), op: .setPinned(conversation: ConversationID(dm), rank: 0)))
        }
        _ = try? await source.submit(HomeIntent(key: IdempotencyKey("cmk_typing"), op: .setTyping(conversation: ConversationID(dm), on: true)))
        let mark = tape.all.count
        source.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: Self.other)
        // The revocation, when there is one, comes before the emptied inbox.
        #expect(await tape.wait { inboxCount($0[mark...]) >= 1 })
        let revoked = tape.all.flatMap { event -> [IdempotencyKey] in
            if case .intentsRevoked(let keys) = event { Array(keys) } else { [] }
        }
        #expect(revoked.isEmpty, "held for revocation: \(revoked)")
    }

    /// A and B share a conversation. A's unsubscribe after the switch must
    /// reach the daemon before B's subscribe, or it ends B's subscription.
    @Test func aConversationBothAccountsShareStaysSubscribedAfterTheSwitch() async throws {
        let (source, daemon, tape) = await configured(.init(heads: [dm: F.head(dm)]))
        #expect(await signedIn(tape))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        let gate = Gate()
        daemon.script.withLock { $0.unsubscribeGate = gate }
        source.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: Self.other)
        await gate.arrived()
        let reopened = Mutex(false)
        let reopen = Task {
            _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
            reopened.withLock { $0 = true }
        }
        // Gives B's open every chance to overtake A's held unsubscribe.
        var turns = 0
        while turns < 10_000, !reopened.withLock({ $0 }) {
            turns += 1
            await Task.yield()
        }
        gate.open()
        try await reopen.value
        #expect(await daemon.wait { $0.contains(.unsubscribe(dm)) })
        #expect(daemon.subscribed.contains(dm), "B's subscription ended: \(daemon.calls)")
    }

    func event(_ name: String, _ json: String) -> CloudConversationsEvent? {
        if case .cloudConversations(let event) = DaemonEvent.decode(name: name, line: Data(json.utf8)) { event } else { nil }
    }

    /// An edit goes out only while its conversation's socket is `live`
    /// (home-cloud-proxy.md section 5): before that it waits
    /// (`ownerUnreachable`) and the store resends it once the socket is live.
    @Test func editsWaitUntilTheConversationIsLive() async throws {
        let other = "conv_dm_01J0000000000000000000000D"
        let (source, daemon, _) = await configured(.init(heads: [dm: F.head(dm), other: F.head(other)], subscribeState: "connecting"))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        let send = HomeIntent(key: IdempotencyKey("cmk_c"), op: .sendMessage(conversation: ConversationID(dm), parts: [.text("x")]))
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.submit(send) }
        #expect(daemon.opRequests.isEmpty)
        source.handle(.subscriptionState(CloudSubscriptionState(scope: "conversation", conversation: dm, state: "live")))
        _ = try await source.submit(send)
        #expect(daemon.opRequests.map(\.idempotencyKey) == ["cmk_c"])

        // A conversation without a subscription subscribes, and its edit waits for it.
        let unopened = HomeIntent(key: IdempotencyKey("cmk_u"), op: .sendMessage(conversation: ConversationID(other), parts: [.text("y")]))
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.submit(unopened) }
        #expect(await daemon.wait { $0.contains(.subscribe(other)) })
        #expect(daemon.opRequests.map(\.idempotencyKey) == ["cmk_c"])
    }

    /// A subscribe reply or a socket state the daemon names for another
    /// account (a socket still on the previous lease) does not make the
    /// conversation live for this one; an inbox reset for another account
    /// lists nothing again.
    @Test func socketStatesAndResetsForAnotherAccountAreIgnored() async throws {
        let (source, daemon, tape) = await configured(.init(heads: [dm: F.head(dm)], subscribeAccount: "user_stack-other"))
        #expect(await signedIn(tape))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        let send = HomeIntent(key: IdempotencyKey("cmk_s"), op: .sendMessage(conversation: ConversationID(dm), parts: [.text("x")]))
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.submit(send) }
        let liveForOther = try #require(event("cloud-subscription-state", #"""
        {"event":"cloud-subscription-state","scope":"conversation","conversation":"\#(dm)","state":"live","account":"user_stack-other"}
        """#))
        source.handle(liveForOther)
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.submit(send) }
        #expect(daemon.opRequests.isEmpty)
        let liveForMe = try #require(event("cloud-subscription-state", #"""
        {"event":"cloud-subscription-state","scope":"conversation","conversation":"\#(dm)","state":"live","account":"user_stack-me"}
        """#))
        source.handle(liveForMe)
        _ = try await source.submit(send)
        #expect(daemon.opRequests.map(\.idempotencyKey) == ["cmk_s"])

        let resetForOther = try #require(event("cloud-inbox-reset", #"{"event":"cloud-inbox-reset","seq":3,"account":"user_stack-other"}"#))
        let resetForMe = try #require(event("cloud-inbox-reset", #"{"event":"cloud-inbox-reset","seq":4,"account":"stack-me"}"#))
        #expect(!CloudHomeSource.isForAccount(resetForOther, cloudID: F.identity.cloudID), "an inbox reset for another account is kept")
        #expect(CloudHomeSource.isForAccount(resetForMe, cloudID: F.identity.cloudID))
    }

    /// The account filter alone: the account an event names, as a cloud id
    /// or a bare Stack user id, against the account the source acts as.
    @Test func anEventBelongsOnlyToTheAccountItNames() throws {
        let me = F.identity.cloudID
        let mine = CloudConversationsEvent.subscriptionState(CloudSubscriptionState(scope: "inbox", state: "live", account: "stack-me"))
        let prefixed = CloudConversationsEvent.subscriptionState(CloudSubscriptionState(scope: "inbox", state: "live", account: "user_stack-me"))
        let theirs = CloudConversationsEvent.inboxChanged(CloudInboxChanged(seq: 1, entries: [], account: "stack-other"))
        #expect(CloudHomeSource.isForAccount(mine, cloudID: me))
        #expect(CloudHomeSource.isForAccount(prefixed, cloudID: me))
        #expect(!CloudHomeSource.isForAccount(theirs, cloudID: me))
        #expect(!CloudHomeSource.isForAccount(mine, cloudID: nil), "an event that names an account reached a signed-out source")
        #expect(CloudHomeSource.isForAccount(.sessionNeeded(CloudSessionNeeded(reason: "missing")), cloudID: me))
    }

    /// The daemon tags every data event with the account of the socket's
    /// lease, and leaves it out only for a lease without a readable `sub`,
    /// which this app never sets (home-cloud-proxy.md section 5). A data
    /// event without one is refused; a socket state or an inbox reset
    /// without one (a `disconnected` state with no lease) carries no data.
    @Test func aDataEventThatNamesNoAccountIsRefused() {
        let me = F.identity.cloudID
        let changed = CloudConversationsEvent.changed(CloudConversationChanged(conversation: dm, rev: 1, seq: 1, change: .unknown(kind: "invite")))
        let resynced = CloudConversationsEvent.resynced(CloudConversationResynced(conversation: dm, rev: 1, seq: 1, summary: F.head(dm), messages: []))
        let inbox = CloudConversationsEvent.inboxChanged(CloudInboxChanged(seq: 1, entries: [F.entry(dm)]))
        #expect(!CloudHomeSource.isForAccount(changed, cloudID: me))
        #expect(!CloudHomeSource.isForAccount(resynced, cloudID: me))
        #expect(!CloudHomeSource.isForAccount(inbox, cloudID: me))
        #expect(CloudHomeSource.isForAccount(.inboxReset(seq: 1), cloudID: me))
        let disconnected = CloudConversationsEvent.subscriptionState(CloudSubscriptionState(scope: "inbox", state: "disconnected",
                                                                                            reason: "signed_out"))
        #expect(CloudHomeSource.isForAccount(disconnected, cloudID: me))
    }

    /// The owner refused the conversation's socket (`closed`, `forbidden`:
    /// the user was removed). An edit there is refused for good and
    /// subscribes nothing, instead of waiting forever and opening a socket
    /// the Worker refuses on every resend. Opening it again tries again.
    @Test func anEditInAClosedConversationIsRefusedAndSubscribesNothing() async throws {
        let (source, daemon, tape) = await configured(.init(heads: [dm: F.head(dm)]))
        #expect(await signedIn(tape))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        source.handle(.subscriptionState(CloudSubscriptionState(scope: "conversation", conversation: dm, state: "closed",
                                                                reason: "forbidden", account: "stack-me")))
        @Sendable func subscribes(_ calls: [FakeCloudDaemon.Call]) -> Int { calls.filter { $0 == .subscribe(dm) }.count }
        let before = subscribes(daemon.calls)
        let send = HomeIntent(key: IdempotencyKey("cmk_closed"), op: .sendMessage(conversation: ConversationID(dm), parts: [.text("x")]))
        await #expect(throws: HomeRejection.notAuthorized) { try await source.submit(send) }
        let read = HomeIntent(key: IdempotencyKey("cmk_closed_read"), op: .setReadCursor(conversation: ConversationID(dm), seq: 1))
        await #expect(throws: HomeRejection.notAuthorized) { try await source.submit(read) }
        #expect(daemon.opRequests.isEmpty)

        // The user opens it again: it subscribes once more, and edits go out once it is live.
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        #expect(subscribes(daemon.calls) == before + 1, "an edit in a closed conversation subscribed it: \(daemon.calls)")
        _ = try await source.submit(send)
        #expect(daemon.opRequests.map(\.idempotencyKey) == ["cmk_closed"])
    }

    /// The `.ownerRecovered` that resends edits refused while a socket
    /// connected comes from that socket's `live` state.
    @Test func aLiveSocketAfterARefusedEditTellsTheStoreToResend() async throws {
        let (source, _, tape) = await configured(.init(heads: [dm: F.head(dm)], subscribeState: "connecting"))
        #expect(await signedIn(tape))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        @Sendable func recoveries(_ events: [HomeEvent]) -> Int { events.filter { $0 == .ownerRecovered }.count }
        let before = recoveries(tape.all)
        let send = HomeIntent(key: IdempotencyKey("cmk_lv"), op: .sendMessage(conversation: ConversationID(dm), parts: [.text("x")]))
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.submit(send) }
        source.handle(.subscriptionState(CloudSubscriptionState(scope: "conversation", conversation: dm, state: "live", account: "stack-me")))
        #expect(await tape.wait { recoveries($0) == before + 1 })
    }

    /// "Open" means on screen now: closing a transcript ends its
    /// subscription, and a conversation the inbox does not list (opened from
    /// the archive or a deep link) leaves the inbox. A listed one stays.
    @Test func closingATranscriptEndsItsSubscriptionAndAnUnlistedConversationLeaves() async throws {
        let listedID = "conv_dm_01J0000000000000000000000K"
        let (source, daemon, tape) = await configured(.init(entries: [F.entry(listedID)],
                                                            heads: [dm: F.head(dm), listedID: F.head(listedID)]))
        #expect(await signedIn(tape))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        _ = try await source.snapshot(of: ConversationID(listedID), tail: 10)
        #expect(listed(source, dm), "an open conversation is not shown")

        source.close(ConversationID(dm))
        #expect(await daemon.wait { $0.contains(.unsubscribe(dm)) })
        #expect(!listed(source, dm), "a closed unlisted conversation stayed in the inbox")
        #expect(await tape.wait { $0.contains { if case .conversationRemoved(let id, _) = $0 { id.rawValue == dm } else { false } } })

        source.close(ConversationID(listedID))
        #expect(await daemon.wait { $0.contains(.unsubscribe(listedID)) })
        #expect(listed(source, listedID), "a listed conversation left the inbox when its transcript closed")
    }

    /// The daemon reconnects: the open conversations subscribe again
    /// before the inbox lists, so the inbox the store gets still shows them
    /// (the router removes what a cloud inbox leaves out).
    @Test func aReconnectKeepsTheOpenConversationsListed() async throws {
        let (source, _, tape) = await configured(.init(heads: [dm: F.head(dm)]))
        #expect(await signedIn(tape))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        let mark = tape.all.count
        let second = FakeCloudDaemon(.init(heads: [dm: F.head(dm)]))
        source.configure(commands: second, link: ObjectIdentifier(second), identity: F.identity)
        @Sendable func inboxes(_ events: [HomeEvent]) -> [InboxSnapshot] {
            events.dropFirst(mark).compactMap { if case .inbox(let inbox) = $0 { inbox } else { nil } }
        }
        #expect(await tape.wait { !inboxes($0).isEmpty })
        let first = try #require(inboxes(tape.all).first)
        #expect(first.conversations.contains { $0.id.rawValue == dm }, "the reconnect's inbox dropped an open conversation")
        #expect(await second.wait { $0.contains(.subscribe(dm)) })
    }

    /// The daemon holds no lease (another trusted local client cleared
    /// it): nothing was sent. The op waits instead of failing for good, and
    /// the source asks the link for a lease.
    @Test func anOpTheDaemonRefusesWithoutALeaseWaitsAndAsksForOne() async throws {
        let (source, daemon, tape) = await configured(.init(op: { _ in
            throw DaemonError.command(cmd: "cloud-conversation-op", message: "signed out", code: "cloud_signed_out",
                                      details: .object(["reason": .string("missing")]), retryable: false)
        }))
        #expect(await signedIn(tape))
        let asked = Mutex(0)
        source.onLeaseMissing { asked.withLock { $0 += 1 } }
        let invite = HomeIntent(key: IdempotencyKey("cmk_so"), op: .invite(contact: .email("z@y.com")))
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.submit(invite) }
        #expect(asked.withLock { $0 } == 1, "no lease was asked for")
        // Until a lease arrives nothing more goes out.
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.submit(invite) }
        #expect(daemon.ops.count == 1)
    }

    /// The daemon's lease expired (`cloud_session_expired`): nothing was
    /// sent. The op waits, and the source asks the link for a lease instead
    /// of staying down until the link changes.
    @Test func anOpRefusedForAnExpiredLeaseWaitsAndAsksForOne() async throws {
        let (source, daemon, tape) = await configured(.init(op: { _ in
            throw DaemonError.command(cmd: "cloud-conversation-op", message: "expired", code: "cloud_session_expired",
                                      details: .object(["reason": .string("expired")]), retryable: true)
        }))
        #expect(await signedIn(tape))
        let asked = Mutex(0)
        source.onLeaseMissing { asked.withLock { $0 += 1 } }
        let invite = HomeIntent(key: IdempotencyKey("cmk_exp"), op: .invite(contact: .email("z@y.com")))
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.submit(invite) }
        #expect(asked.withLock { $0 } == 1, "an expired lease asked for no new one")
        #expect(daemon.ops.count == 1)
    }

    /// A close queues its unsubscribe behind the subscribe it ends, so the
    /// daemon never ends up streaming a conversation the source no longer
    /// tracks (round-5 review, minor 3).
    @Test func aCloseRightAfterAReopenNeverLeavesTheDaemonSubscribed() async throws {
        let unsubscribes = Gate()
        let (source, daemon, tape) = await configured(.init(heads: [dm: F.head(dm)], unsubscribeGate: unsubscribes))
        #expect(await signedIn(tape))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        source.close(ConversationID(dm))
        await unsubscribes.arrived()
        let subscribes = Gate()
        daemon.script.withLock { $0.subscribeGate = subscribes }
        let reopen = Task { try? await source.snapshot(of: ConversationID(dm), tail: 10) }
        for _ in 0..<500 { await Task.yield() }
        source.close(ConversationID(dm))
        unsubscribes.open()
        await subscribes.arrived()
        // Room for an unsubscribe that does not wait for the subscribe to overtake it.
        try await Task.sleep(for: .milliseconds(200))
        subscribes.open()
        _ = await reopen.value
        @Sendable func count(_ calls: [FakeCloudDaemon.Call], _ call: FakeCloudDaemon.Call) -> Int { calls.filter { $0 == call }.count }
        #expect(await daemon.wait { count($0, .unsubscribe(dm)) == 2 && count($0, .subscribe(dm)) == 2 })
        #expect(!daemon.subscribed.contains(dm), "the daemon streams a closed conversation: \(daemon.calls)")
    }

    /// An edit made outside a transcript (mark read from the inbox, a
    /// quick reply) subscribes its conversation so the edit can go out;
    /// with no transcript showing it, the subscription ends after the op.
    /// An open transcript keeps its own.
    @Test func anEditOutsideATranscriptEndsTheSubscriptionItMade() async throws {
        let other = "conv_dm_01J0000000000000000000000Q"
        let (source, daemon, tape) = await configured(.init(entries: [F.entry(dm), F.entry(other)],
                                                            heads: [dm: F.head(dm), other: F.head(other)]))
        #expect(await signedIn(tape))
        _ = try await source.snapshot(of: ConversationID(other), tail: 10)
        _ = try await source.submit(HomeIntent(key: IdempotencyKey("cmk_open_read"),
                                               op: .setReadCursor(conversation: ConversationID(other), seq: 1)))

        let mark = tape.all.count
        let read = HomeIntent(key: IdempotencyKey("cmk_inbox_read"), op: .setReadCursor(conversation: ConversationID(dm), seq: 1))
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.submit(read) }
        #expect(await tape.wait { $0.dropFirst(mark).contains(.ownerRecovered) })
        _ = try await source.submit(read)
        #expect(await daemon.wait { $0.contains(.unsubscribe(dm)) }, "the edit left a subscription no close ends")
        #expect(!daemon.calls.contains(.unsubscribe(other)), "an edit ended an open transcript's subscription")
        #expect(!daemon.subscribed.contains(dm))
    }

    /// Revoked keys are kept per account and pruned when that account
    /// signs in again: its own keys never commit as another account, and
    /// the set does not only grow.
    @Test func anAccountsOwnKeysAreNoLongerRevokedWhenItSignsInAgain() async throws {
        let dm = dm
        let (source, daemon, tape) = await configured(.init(heads: [dm: F.head(dm)], op: { _ in throw F.unavailable() }))
        #expect(await signedIn(tape))
        let invite = HomeIntent(key: IdempotencyKey("cmk_back"), op: .invite(contact: .email("z@y.com")))
        await #expect(throws: HomeRejection.indeterminate) { try await source.submit(invite) }
        source.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: Self.other)
        await #expect(throws: HomeRejection.notAuthorized) { try await source.submit(invite) }
        source.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: F.identity)
        daemon.script.withLock { $0.op = { _ in CloudConversationOpResult(conversation: F.head(dm, rev: 1, lastSeq: 0)) } }
        _ = try await source.submit(invite)
        #expect(daemon.ops.count == 2, "the account's own key stayed revoked: \(daemon.calls)")
    }

    func listed(_ source: CloudHomeSource, _ id: String) -> Bool {
        source.currentInbox().conversations.contains { $0.id.rawValue == id }
    }

    /// An inbox list reply is UserDO's inbox at its revision (the inbox
    /// stream seq). An inbox event past that revision is newer: a reply
    /// that arrives after it never undoes it (a new DM stays listed, an
    /// archive stays archived).
    @Test func aStaleInboxListNeverUndoesANewerInboxEvent() async throws {
        let fresh = "conv_dm_01J0000000000000000000000H"
        let (source, daemon, tape) = await configured(.init(heads: [dm: F.head(dm), fresh: F.head(fresh)]))
        #expect(await signedIn(tape))

        let first = Gate()
        daemon.script.withLock { $0.inboxGate = first; $0.revision = .string("12") }
        let list = Task { try await source.inbox() }
        await first.arrived()
        source.handle(.inboxChanged(CloudInboxChanged(seq: 13, entries: [F.entry(fresh)], account: "stack-me")))
        first.open()
        _ = try await list.value
        #expect(listed(source, fresh), "a list older than the inbox event removed the new DM")

        let second = Gate()
        daemon.script.withLock { script in
            script.inboxGate = second
            script.entries = [F.entry(fresh), F.entry(dm)]
            script.revision = .string("14")
        }
        let relist = Task { try await source.inbox() }
        await second.arrived()
        source.handle(.inboxChanged(CloudInboxChanged(seq: 15, entries: [F.entry(fresh, rev: 4, archived: true)], account: "stack-me")))
        second.open()
        _ = try await relist.value
        #expect(!listed(source, fresh), "a list older than the archive listed it again")
        #expect(listed(source, dm))

        // A list at or past the event's seq is current again.
        daemon.script.withLock { script in
            script.inboxGate = nil
            script.entries = [F.entry(fresh, rev: 5)]
            script.revision = .number(15)
        }
        _ = try await source.inbox()
        #expect(listed(source, fresh))
        #expect(!listed(source, dm))
    }

    /// The daemon names the account whose lease an event came through.
    /// An event for another account (a late one from before a switch) is
    /// dropped, and so is a data event that names none.
    @Test func anEventForAnotherAccountIsDropped() async throws {
        let theirs = "conv_dm_01J0000000000000000000000F"
        let mine = "conv_dm_01J0000000000000000000000J"
        let (source, _, tape) = await configured(.init(heads: [dm: F.head(dm)]))
        #expect(await signedIn(tape))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        let decoder = JSONDecoder()
        func entry(_ id: String) -> String {
            #"{"conversation":"\#(id)","rev":3,"kind":"dm","title":"","last_seq":1,"last_at":"\#(F.at)","preview":"Bob: hi","dm_peer":"user_bob"}"#
        }
        let lateInbox = try decoder.decode(CloudInboxChanged.self, from: Data(#"{"seq":5,"account":"user_stack-other","entries":[\#(entry(theirs))]}"#.utf8))
        let lateCursor = try decoder.decode(CloudConversationChanged.self, from: Data(#"""
        {"conversation":"\#(dm)","rev":9,"seq":20,"account":"user_stack-other","change":{"kind":"read-cursor","participant":"user_bob","seq":1}}
        """#.utf8))
        let lateResync = try decoder.decode(CloudConversationResynced.self, from: Data(#"""
        {"conversation":"\#(dm)","rev":9,"seq":20,"account":"user_stack-other","summary":{"id":"\#(dm)","owner":"cloud","kind":"dm","title":"",
         "participants":[],"last_seq":1,"rev":9,"created_at":"\#(F.at)","updated_at":"\#(F.at)","read_cursors":{}},"messages":[]}
        """#.utf8))
        let ownInbox = try decoder.decode(CloudInboxChanged.self, from: Data(#"{"seq":6,"account":"user_stack-me","entries":[\#(entry(mine))]}"#.utf8))
        source.handle(.inboxChanged(lateInbox))
        source.handle(.changed(lateCursor))
        source.handle(.resynced(lateResync))
        source.handle(.inboxChanged(ownInbox))
        // A data event that names no account came through a lease without a
        // readable `sub`, which this app never sets: it is dropped too.
        let nameless = "conv_dm_01J0000000000000000000000N"
        source.handle(.inboxChanged(CloudInboxChanged(seq: 7, entries: [F.entry(nameless)])))
        source.handle(.inboxChanged(CloudInboxChanged(seq: 8, entries: [F.entry(dm)], account: "stack-me")))
        #expect(await tape.wait { !summaries($0, mine).isEmpty && !summaries($0, dm).isEmpty })
        #expect(summaries(tape.all, nameless).isEmpty, "an inbox event without an account listed its conversation")
        #expect(summaries(tape.all, theirs).isEmpty, "another account's inbox event listed its conversation")
        #expect(!tape.all.contains { if case .conversationPage = $0 { true } else { false } }, "another account's resync reached the store")
        #expect(!tape.all.contains { if case .conversationChanged(_, stream: .conversation, rev: 9) = $0 { true } else { false } },
                "another account's cursor reached the store")
    }

    /// While the daemon holds no lease for this account (it may still hold
    /// the previous one's, when clearing it failed), no read goes out: a
    /// reply could be the previous account's.
    @Test func noReadGoesOutWithoutTheLease() async throws {
        let theirs = "conv_dm_01J0000000000000000000000F"
        let daemon = FakeCloudDaemon(.init(heads: [theirs: F.head(theirs)], inboxBySubject: ["a": [F.entry(theirs)]]))
        _ = try await daemon.setSession(CloudSessionSetRequest(apiBaseURL: "https://cloud-api.test", accessToken: F.jwt(sub: "a"),
                                                               expiresAt: 1, clientVersion: nil))
        let source = CloudHomeSource(me: Participant(id: F.localMe, kind: .human, displayName: "Me"))
        source.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: F.identity, leased: false)
        _ = try? await source.inbox()
        #expect(!listed(source, theirs), "the previous account's inbox shown")
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.snapshot(of: ConversationID(theirs), tail: 10) }
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.history(of: ConversationID(theirs), before: 2, limit: 10) }
        #expect(!daemon.calls.contains { if case .snapshot = $0 { true } else if case .history = $0 { true } else { false } })
    }
}

/// The token lease the app gives the daemon (home-cloud-proxy.md section 2).
@Suite struct HomeCloudLeaseTests {
    @Test func theExpiryIsTheTokensExpClaimInMilliseconds() {
        func jwt(_ payload: String) -> String {
            let body = Data(payload.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "eyJhbGciOiJIUzI1NiJ9.\(body).sig"
        }
        #expect(HomeCloudLease.expiry(ofJWT: jwt(#"{"sub":"u","exp":1790000000}"#)) == 1_790_000_000_000)
        #expect(HomeCloudLease.expiry(ofJWT: jwt(#"{"sub":"u"}"#)) == nil)
        #expect(HomeCloudLease.expiry(ofJWT: "opaque") == nil)
        #expect(HomeCloudLease.fallbackExpiry(now: Date(timeIntervalSince1970: 1000)) == 1_300_000)
    }

    /// An `exp` out of range is not trusted (and never traps): the lease falls back.
    @Test func anExpOutOfRangeIsIgnored() {
        func jwt(_ payload: String) -> String {
            let body = Data(payload.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "eyJhbGciOiJIUzI1NiJ9.\(body).sig"
        }
        #expect(HomeCloudLease.expiry(ofJWT: jwt(#"{"exp":1e300}"#)) == nil)
        // Year 2096: far past any token lifetime.
        #expect(HomeCloudLease.expiry(ofJWT: jwt(#"{"exp":4000000000}"#)) == nil)
        let soon = Int(Date().timeIntervalSince1970) + 3600
        #expect(HomeCloudLease.expiry(ofJWT: jwt(#"{"exp":\#(soon)}"#)) == UInt64(soon) * 1000)
    }

    /// The lease is checked against the account the token names.
    @Test func theSubjectIsTheTokensSubClaim() {
        #expect(HomeCloudLease.subject(ofJWT: CloudFixtures.jwt(sub: "u-1")) == "u-1")
        #expect(HomeCloudLease.subject(ofJWT: "opaque") == nil)
        #expect(CloudIdentity.cloudID(stackUserID: "u-1") == CloudIdentity.cloudID(stackUserID: "user_u-1"))
    }

    @Test func theLeaseNamesOnlyTheAPIOrigin() {
        #expect(HomeCloudLease.origin(URL(string: "https://cloud-api.cmux.dev/v1/")!) == "https://cloud-api.cmux.dev")
        #expect(HomeCloudLease.origin(URL(string: "http://127.0.0.1:8787")!) == "http://127.0.0.1:8787")
    }
}
