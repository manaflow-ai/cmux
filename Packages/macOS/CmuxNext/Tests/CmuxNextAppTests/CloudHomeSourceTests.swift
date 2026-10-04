import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The cloud Home source over the daemon proxy (home-cloud-proxy.md, part 2):
/// it reads and writes only through `cloud-conversations-v1`, keeps the
/// owners' ids, and shows the signed-in account as the store's one `me`.
@Suite(.timeLimit(.minutes(1))) struct CloudHomeSourceTests {
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
        func recoveries(_ events: [HomeEvent]) -> Int { events.filter { $0 == .ownerRecovered }.count }
        #expect(await tape.wait { $0.contains { if case .inbox = $0 { true } else { false } } })
        let before = recoveries(tape.all)
        let send = HomeIntent(key: IdempotencyKey("cmk_l"), op: .sendMessage(conversation: ConversationID(dm), parts: [.text("x")]))
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.submit(send) }
        source.leaseRenewed()
        #expect(await tape.wait { recoveries($0) == before + 1 })
        // Nothing failed since: a second renewal is not a recovery.
        source.leaseRenewed()
        source.handle(.inboxChanged(CloudInboxChanged(seq: 4, entries: [F.entry(dm)])))
        #expect(await tape.wait { !summaries($0, dm).isEmpty })
        #expect(recoveries(tape.all) == before + 1)
    }

    @Test func ownerEventsBecomeHomeEventsWithTheOwnersRevisions() async throws {
        let (source, _, tape) = await configured(.init(heads: [dm: F.head(dm)]))
        _ = try await source.snapshot(of: ConversationID(dm), tail: 10)
        source.handle(.changed(CloudConversationChanged(conversation: dm, rev: 4, seq: 9,
                                                        change: .message(F.message(dm, seq: 2, author: "user_stack-me")))))
        source.handle(.changed(CloudConversationChanged(conversation: dm, rev: 5, seq: 10,
                                                        change: .readCursor(participant: "user_bob", seq: 2))))
        source.handle(.changed(CloudConversationChanged(conversation: dm, rev: 6, seq: 11, change: .unknown(kind: "invite"))))
        source.handle(.resynced(CloudConversationResynced(conversation: dm, rev: 6, seq: 11, summary: F.head(dm, rev: 6, lastSeq: 2),
                                                          messages: [F.message(dm, seq: 1), F.message(dm, seq: 2)])))
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
        #expect(reject("cloud_signed_out", "missing") == .notAuthorized)
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
        await #expect(throws: HomeRejection.indeterminate) { try await source.submit(start) }
        daemon.script.withLock { $0.op = { _ in CloudConversationOpResult(conversation: F.head(opened, rev: 1, lastSeq: 0)) } }
        let before = daemon.opRequests.count
        let other = CloudIdentity(stackUserID: "stack-other", displayName: "Other", localID: F.localMe)
        source.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: other)
        // The store is told to drop it before any reply for the new account can recover it.
        #expect(await tape.wait { $0.contains(.intentsRevoked([start.key])) })
        let revoked = try #require(tape.all.firstIndex(of: .intentsRevoked([start.key])))
        #expect(!tape.all[revoked...].contains(.ownerRecovered))
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
        source.handle(.inboxChanged(CloudInboxChanged(seq: 5, entries: [F.entry(dm, archived: true)])))
        source.handle(.changed(CloudConversationChanged(conversation: dm, rev: 4, seq: 9, change: .readCursor(participant: "user_bob", seq: 1))))
        source.handle(.changed(CloudConversationChanged(conversation: dm, rev: 5, seq: 10, change: .conversation(F.head(dm, rev: 5)))))
        source.handle(.resynced(CloudConversationResynced(conversation: dm, rev: 6, seq: 11, summary: F.head(dm, rev: 6),
                                                          messages: [F.message(dm, seq: 1)])))
        source.handle(.inboxChanged(CloudInboxChanged(seq: 6, entries: [F.entry(other)])))
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
        func inboxes(_ events: [HomeEvent]) -> [InboxSnapshot] {
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
        source.handle(.inboxChanged(CloudInboxChanged(seq: 8, entries: [F.entry(opened, rev: 1, lastSeq: 0)])))
        source.handle(.inboxChanged(CloudInboxChanged(seq: 9, entries: [F.entry(opened, rev: 2, lastSeq: 0, archived: true)])))
        #expect(!source.currentInbox().conversations.contains { $0.id.rawValue == opened })
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

    @Test func theLeaseNamesOnlyTheAPIOrigin() {
        #expect(HomeCloudLease.origin(URL(string: "https://cloud-api.cmux.dev/v1/")!) == "https://cloud-api.cmux.dev")
        #expect(HomeCloudLease.origin(URL(string: "http://127.0.0.1:8787")!) == "http://127.0.0.1:8787")
    }
}
