import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Synchronization
import Testing
@testable import CmuxNextApp

/// Account switches, hydration and which account an event belongs to.
nonisolated extension CloudHomeSourceTests {
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
}
