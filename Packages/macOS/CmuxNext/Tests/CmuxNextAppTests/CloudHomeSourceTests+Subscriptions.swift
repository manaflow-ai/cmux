import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Synchronization
import Testing

@testable import CmuxNextApp

extension CloudHomeSourceTests {
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
        // The first unsubscribe goes; the reopen's subscribe reaches the daemon and is held there.
        unsubscribes.open()
        await subscribes.arrived()
        // The close comes while that subscribe is in flight: its unsubscribe queues behind it.
        source.close(ConversationID(dm))
        // Room for an unsubscribe that does not wait for the subscribe to overtake it.
        try await Task.sleep(for: .milliseconds(200))
        subscribes.open()
        _ = await reopen.value
        @Sendable func count(_ calls: [FakeCloudDaemon.Call], _ call: FakeCloudDaemon.Call) -> Int { calls.filter { $0 == call }.count }
        #expect(await daemon.wait { count($0, .unsubscribe(dm)) == 2 && count($0, .subscribe(dm)) == 2 })
        #expect(!daemon.subscribed.contains(dm), "the daemon streams a closed conversation: \(daemon.calls)")
    }

    /// The store calls the source off the main actor, so its close can run
    /// after the read marked the conversation viewed and before it
    /// subscribed (round-6 review, finding 1). That close ends nothing; the
    /// store closes again when the read returns, which ends the
    /// subscription the read made.
    @Test @MainActor func aCloseBeforeTheReadSubscribesNeverLeavesTheDaemonSubscribed() async throws {
        let (source, daemon, tape) = await configured(.init(heads: [dm: F.head(dm)]))
        #expect(await signedIn(tape))
        let store = HomeStore(source: source)
        let id = ConversationID(dm)
        source.setSnapshotWillSubscribe { await MainActor.run { store.close(id) } }
        await store.open(id)
        source.setSnapshotWillSubscribe(nil)
        #expect(daemon.calls.contains(.subscribe(dm)))
        #expect(await daemon.wait { $0.contains(.unsubscribe(dm)) }, "the daemon streams a closed conversation: \(daemon.calls)")
        #expect(!daemon.subscribed.contains(dm))
        #expect(!listed(source, dm), "a closed unlisted conversation stayed in the inbox")
    }

    /// An edit made outside a transcript (mark read from the inbox, a
    /// quick reply) subscribes its conversation so the edit can go out and
    /// its echo can settle the intent. With no transcript showing it, the
    /// subscription ends with that echo (round-6 review, finding 2), not
    /// with the op's reply, which can come first. An open transcript keeps
    /// its own.
    @Test func anEditOutsideATranscriptEndsItsSubscriptionWithItsEcho() async throws {
        let other = "conv_dm_01J0000000000000000000000Q"
        let (source, daemon, tape) = await configured(.init(entries: [F.entry(dm), F.entry(other)],
                                                            heads: [dm: F.head(dm), other: F.head(other)]))
        #expect(await signedIn(tape))
        _ = try await source.snapshot(of: ConversationID(other), tail: 10)
        _ = try await source.submit(HomeIntent(key: IdempotencyKey("cmk_open_read"),
                                               op: .setReadCursor(conversation: ConversationID(other), seq: 1)))

        let read = try await submitFromInbox(source, tape, key: "cmk_inbox_read")
        #expect(read.rev == 2)
        for _ in 0..<2_000 { await Task.yield() }
        #expect(!daemon.calls.contains(.unsubscribe(dm)), "the subscription ended before the echo arrived")
        source.handle(.changed(echo(dm, rev: 1)))
        for _ in 0..<500 { await Task.yield() }
        #expect(!daemon.calls.contains(.unsubscribe(dm)), "an older event ended the subscription")
        source.handle(.changed(echo(dm, rev: 2)))
        #expect(await daemon.wait { $0.contains(.unsubscribe(dm)) }, "the echo left a subscription no close ends")
        #expect(!daemon.calls.contains(.unsubscribe(other)), "an edit ended an open transcript's subscription")
        #expect(!daemon.subscribed.contains(dm))
    }

    /// The echo can come before the op's reply: the reply then ends the subscription.
    @Test func anEchoBeforeTheReplyEndsTheSubscriptionWithTheReply() async throws {
        let (source, daemon, tape) = await configured(.init(entries: [F.entry(dm)], heads: [dm: F.head(dm)]))
        #expect(await signedIn(tape))
        let early = echo(dm, rev: 2)
        daemon.script.withLock { script in
            script.op = { [source] _ in
                source.handle(.changed(early))
                return CloudConversationOpResult(rev: 2)
            }
        }
        _ = try await submitFromInbox(source, tape, key: "cmk_echo_first")
        #expect(await daemon.wait { $0.contains(.unsubscribe(dm)) })
    }

    /// The echo never comes (lost on the socket): the subscription ends at the deadline.
    @Test func withoutAnEchoTheEditSubscriptionEndsAtTheDeadline() async throws {
        let clock = ManualClock()
        let (source, daemon, tape) = await configured(.init(entries: [F.entry(dm)], heads: [dm: F.head(dm)]), clock: clock)
        #expect(await signedIn(tape))
        _ = try await submitFromInbox(source, tape, key: "cmk_no_echo")
        for _ in 0..<2_000 { await Task.yield() }
        #expect(!daemon.calls.contains(.unsubscribe(dm)), "the subscription ended before the deadline")
        await clock.sleepers(atLeast: 1)
        clock.advance(by: CloudHomeSource.editEchoDeadline)
        #expect(await daemon.wait { $0.contains(.unsubscribe(dm)) }, "a lost echo left a subscription no close ends")
    }

    /// A refusal the store may resend keeps the subscription for the
    /// resend; when the store gives up instead (it never tells the source),
    /// the subscription ends at the deadline.
    @Test func aRefusalThatIsNeverResentEndsTheSubscriptionAtTheDeadline() async throws {
        let clock = ManualClock()
        let (source, daemon, tape) = await configured(.init(entries: [F.entry(dm)], heads: [dm: F.head(dm)]), clock: clock)
        #expect(await signedIn(tape))
        daemon.script.withLock { $0.op = { _ in throw F.unavailable() } }
        await #expect(throws: HomeRejection.indeterminate) { _ = try await submitFromInbox(source, tape, key: "cmk_lost") }
        for _ in 0..<2_000 { await Task.yield() }
        #expect(!daemon.calls.contains(.unsubscribe(dm)), "a resendable edit lost its socket")
        await clock.sleepers(atLeast: 1)
        clock.advance(by: CloudHomeSource.editEchoDeadline)
        #expect(await daemon.wait { $0.contains(.unsubscribe(dm)) }, "an edit the store gave up on left its subscription")
    }

    /// My read cursor's echo in conversation `id` at `rev`.
    func echo(_ id: String, rev: UInt64) -> CloudConversationChanged {
        CloudConversationChanged(conversation: id, rev: rev, seq: 1, change: .readCursor(participant: "user_stack-me", seq: 1),
                                 account: "stack-me")
    }

    /// Marks `dm` read from the inbox: the first try subscribes and waits
    /// for the live socket, and the store's resend after recovery goes out.
    func submitFromInbox(_ source: CloudHomeSource, _ tape: EventTape, key: String) async throws -> HomeOpResult {
        let mark = tape.all.count
        let read = HomeIntent(key: IdempotencyKey(key), op: .setReadCursor(conversation: ConversationID(dm), seq: 1))
        await #expect(throws: HomeRejection.ownerUnreachable) { try await source.submit(read) }
        #expect(await tape.wait { $0.dropFirst(mark).contains(.ownerRecovered) })
        return try await source.submit(read)
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
