@testable import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Synchronization
import Testing
@testable import CmuxNextApp

/// The local owner as a Home source: one local conversation, and a log of
/// the intents it was asked to apply.
nonisolated final class FakeLocalHomeSource: HomeSource {
    static let conversation = ConversationID("conv_01J00000000000000000000L0C")
    let me = Participant(id: CloudFixtures.localMe, kind: .human, displayName: "Me")
    private let submitted = Mutex<[HomeIntent]>([])
    var intents: [HomeIntent] { submitted.withLock { $0 } }

    var snapshot: InboxSnapshot {
        let chief = Participant(id: ParticipantID("agent_mux"), kind: .agent, displayName: "Chief", agentClass: .chief)
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        return InboxSnapshot(me: me, conversations: [
            ConversationSummary(id: Self.conversation, owner: .local, participants: [me, chief], lastSeq: 0, rev: 1, createdAt: at, updatedAt: at),
        ], rev: 1)
    }

    func events() async -> AsyncStream<HomeEvent> {
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream()
        continuation.yield(.connection(.online))
        continuation.yield(.inbox(snapshot))
        return stream
    }

    func inbox() async throws -> InboxSnapshot { snapshot }
    func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        guard conversation == Self.conversation else { throw HomeRejection.invalid("unknown_conversation") }
        return ConversationPage(conversation: snapshot.conversations[0], messages: [])
    }
    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] { [] }
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        submitted.withLock { $0.append(intent) }
        if let id = intent.op.conversation, id != Self.conversation { throw HomeRejection.invalid("unknown_conversation") }
        if case .createChief = intent.op { throw HomeRejection.invalid("unsupported_on_local_owner") }
        return HomeOpResult(rev: 2, conversation: intent.op.conversation)
    }
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }
    func resolve(_ contact: ContactAddress) async throws -> ContactResolution { .invitable(contact) }
}

/// One Home inbox over the local and the cloud owners
/// (home-cloud-proxy.md part 2): each conversation's reads and ops reach its
/// own owner, and local behavior is unchanged.
@Suite(.timeLimit(.minutes(1))) nonisolated struct HomeSourceRouterTests {
    typealias F = CloudFixtures
    let dm = "conv_dm_01J0000000000000000000000A"

    func router() async -> (HomeSourceRouter, FakeLocalHomeSource, FakeCloudDaemon, CloudHomeSource) {
        let local = FakeLocalHomeSource()
        let daemon = FakeCloudDaemon(.init(entries: [F.entry(dm)], heads: [dm: F.head(dm)]))
        let cloud = CloudHomeSource(me: local.me)
        let router = HomeSourceRouter(local: local, cloud: cloud)
        cloud.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: F.identity)
        return (router, local, daemon, cloud)
    }

    /// The store over the router shows both owners' conversations, the cloud
    /// DM named after its peer once its head arrives.
    @MainActor @Test func oneStoreListsLocalAndCloudConversations() async throws {
        let (router, _, _, _) = await router()
        let store = HomeStore(source: router)
        store.start()
        for await shown in Observations({ store.rows.count == 2 && store.rows.contains { $0.title == "Bob" } }) where shown { break }
        #expect(store.isOnline)
        #expect(Set(store.rows.map(\.summary.owner)) == [.local, .cloud])
        let cloudRow = try #require(store.rows.first { $0.summary.owner == .cloud })
        #expect(cloudRow.title == "Bob")
        #expect(cloudRow.kind == .direct)
        #expect(store.me?.id == F.localMe)
    }

    @Test func eachOpReachesTheOwnerOfItsConversation() async throws {
        let (router, local, daemon, _) = await router()
        _ = try await router.inbox()
        let localSend = HomeIntent(op: .sendMessage(conversation: FakeLocalHomeSource.conversation, parts: [.text("local")]))
        _ = try await router.submit(localSend)
        #expect(local.intents == [localSend])
        #expect(daemon.opRequests.isEmpty)

        _ = try await router.snapshot(of: ConversationID(dm), tail: 10)
        let cloudSend = HomeIntent(key: IdempotencyKey("cmk_c"), op: .sendMessage(conversation: ConversationID(dm), parts: [.text("cloud")]))
        _ = try await router.submit(cloudSend)
        #expect(daemon.opRequests.map(\.idempotencyKey) == ["cmk_c"])
        #expect(local.intents == [localSend])

        // Pin and mute of a local conversation stay with the local owner.
        _ = try await router.submit(HomeIntent(op: .setPinned(conversation: FakeLocalHomeSource.conversation, rank: 0)))
        #expect(local.intents.count == 2)
        // Creating a chief stays local (and refused there); creating a group goes to the cloud.
        await #expect(throws: HomeRejection.invalid("unsupported_on_local_owner")) {
            try await router.submit(HomeIntent(op: .createChief(name: "x")))
        }
        _ = try? await router.submit(HomeIntent(key: IdempotencyKey("cmk_g"), op: .createGroup(title: "G", participants: [])))
        #expect(daemon.opRequests.last?.op.kindName == "conversation.create")
    }

    /// The merged inbox stream's revisions are dense and increasing across
    /// both owners, so the store never sees a false gap or drops an event.
    @Test func mergedInboxRevisionsAreDense() async throws {
        let (router, _, _, cloud) = await router()
        let tape = await EventTape(router)
        #expect(await tape.wait { events in
            events.contains { if case .conversationChanged(let summary, stream: .inbox, rev: _) = $0 { summary.participants.count == 2 } else { false } }
        })
        cloud.handle(.inboxChanged(CloudInboxChanged(seq: 5, entries: [F.entry(dm, rev: 3, pinned: true)], account: "stack-me")))
        cloud.handle(.inboxChanged(CloudInboxChanged(seq: 6, entries: [F.entry(dm, archived: true)], account: "stack-me")))
        #expect(await tape.wait { $0.contains { if case .conversationRemoved = $0 { true } else { false } } })
        let revisions = tape.all.compactMap { event -> Revision? in
            switch event {
            case .inbox(let inbox): inbox.rev
            case .conversationChanged(_, stream: .inbox, rev: let rev): rev
            case .conversationRemoved(_, inboxRev: let rev): rev
            default: nil
            }
        }
        let first = try #require(revisions.first)
        #expect(revisions == Array(first..<(first + Revision(revisions.count))))
    }

    /// A cloud send that failed for a short time (Worker 5xx, token expiry)
    /// is resent with the same key once the cloud side recovers, although
    /// the local daemon's connection never changed.
    @MainActor @Test func aCloudSendThatFailedBrieflyIsResentWithItsKeyWhenTheCloudRecovers() async throws {
        let (router, _, daemon, cloud) = await router()
        daemon.script.withLock { $0.op = { _ in throw F.unavailable() } }
        let store = HomeStore(source: router)
        store.start()
        for await shown in Observations({ store.rows.count == 2 }) where shown { break }
        _ = try await router.snapshot(of: ConversationID(dm), tail: 10)
        let send = HomeOp.sendMessage(conversation: ConversationID(dm), parts: [.text("x")])
        await #expect(throws: HomeSendState.pendingResend) { try await store.perform(send, key: IdempotencyKey("cmk_r")) }
        // The store resends once at once; that fails too.
        #expect(await daemon.wait { $0.filter { if case .op = $0 { true } else { false } }.count >= 2 })
        #expect(await daemon.wait { $0.contains(.subscribe(dm)) })
        let failed = daemon.ops.count
        daemon.script.withLock { $0.op = { _ in CloudConversationOpResult(rev: 4) } }
        cloud.handle(.subscriptionState(CloudSubscriptionState(scope: "conversation", conversation: dm, state: "disconnected")))
        cloud.handle(.subscriptionState(CloudSubscriptionState(scope: "conversation", conversation: dm, state: "live")))
        #expect(await daemon.wait { $0.filter { if case .op = $0 { true } else { false } }.count > failed })
        #expect(Set(daemon.opRequests.map(\.idempotencyKey)) == ["cmk_r"])
    }

    /// An account switch with an unconfirmed cloud intent: the store drops
    /// it, and the first good reply for the new account resends nothing of
    /// the old one (no invite and no message under the wrong identity).
    @MainActor @Test func anAccountSwitchNeverResendsThePreviousAccountsIntents() async throws {
        let opened = "conv_dm_01J0000000000000000000000B"
        let theirs = "conv_dm_01J0000000000000000000000F"
        let (router, _, daemon, cloud) = await router()
        daemon.script.withLock { $0.op = { _ in throw F.unavailable() } }
        let store = HomeStore(source: router)
        store.start()
        for await shown in Observations({ store.isOnline && store.rows.count == 2 }) where shown { break }
        let keyA = IdempotencyKey("cmk_a")
        await #expect(throws: HomeSendState.pendingResend) {
            try await store.perform(.startConversation(contacts: [.email("x@y.com")], firstMessage: [.text("hello")]), key: keyA)
        }
        // The immediate resend fails too: the intent waits for the next recovery.
        #expect(await until { store.log.entries.first { $0.intent.key == keyA }?.state == .unconfirmed })
        let switched = daemon.opRequests.count
        daemon.script.withLock { script in
            script.entries = [F.entry(theirs)]
            script.heads = [theirs: F.head(theirs, participants: [F.participant("user_stack-other", "Other"), F.participant("user_bob", "Bob")])]
            script.op = { _ in CloudConversationOpResult(conversation: F.head(opened, rev: 1, lastSeq: 0)) }
        }
        let other = CloudIdentity(stackUserID: "stack-other", displayName: "Other", localID: F.localMe)
        cloud.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: other)
        for await shown in Observations({ store.rows.contains { $0.id.rawValue == theirs } }) where shown { break }
        _ = try await store.perform(.invite(contact: .email("z@y.com")), key: IdempotencyKey("cmk_b"))
        #expect(await until { !store.log.entries.contains { $0.state == .sending } })
        let sent = daemon.opRequests.dropFirst(switched).map(\.idempotencyKey)
        #expect(!sent.contains { $0.hasPrefix("cmk_a") }, "sent under the new account: \(sent)")
        #expect(!store.log.entries.contains { $0.intent.key == keyA })
    }

    /// A cloud conversation the cloud inbox does not list, opened from a
    /// deep link, a notification or the archive, stays in the merged inbox
    /// while it is open, and its ops keep reaching the cloud.
    @Test func anOpenConversationTheCloudInboxDoesNotListStaysAndReachesTheCloud() async throws {
        let unlisted = "conv_dm_01J0000000000000000000000G"
        let local = FakeLocalHomeSource()
        let daemon = FakeCloudDaemon(.init(entries: [F.entry(dm)], heads: [dm: F.head(dm), unlisted: F.head(unlisted)]))
        let cloud = CloudHomeSource(me: local.me)
        let router = HomeSourceRouter(local: local, cloud: cloud)
        let tape = await EventTape(router)
        cloud.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: F.identity)
        @Sendable func inboxChange(_ event: HomeEvent, _ id: String) -> Bool {
            if case .conversationChanged(let summary, stream: .inbox, rev: _) = event { summary.id.rawValue == id } else { false }
        }
        // Listed and hydrated (named after its peer): no later read publishes it again.
        #expect(await tape.wait { events in
            events.contains { event in
                guard case .conversationChanged(let summary, stream: .inbox, rev: _) = event else { return false }
                return summary.id.rawValue == dm && summary.participants.contains { $0.displayName == "Bob" }
            }
        })
        // Opened on the cloud source: its stream shows it in the merged inbox.
        _ = try await cloud.snapshot(of: ConversationID(unlisted), tail: 10)
        cloud.handle(.changed(CloudConversationChanged(conversation: unlisted, rev: 5, seq: 9, change: .conversation(F.head(unlisted, rev: 5)), account: "stack-me")))
        let mark = tape.all.count
        cloud.handle(.inboxReset(seq: 9))
        // The cloud inbox after the reset reaches the merged stream as a diff.
        #expect(await tape.wait { $0.count > mark && $0[mark...].contains { inboxChange($0, dm) } })
        var mirror = HomeMirror()
        for event in tape.all { mirror.apply(event) }
        #expect(mirror.conversations[ConversationID(dm)] != nil)
        #expect(mirror.conversations[ConversationID(unlisted)] != nil, "an open conversation left the inbox while open")
        let send = HomeIntent(key: IdempotencyKey("cmk_o"), op: .sendMessage(conversation: ConversationID(unlisted), parts: [.text("x")]))
        _ = try? await router.submit(send)
        #expect(local.intents.isEmpty, "a cloud conversation's send reached the local daemon")
        #expect(daemon.opRequests.map(\.idempotencyKey) == ["cmk_o"])
    }

    /// The owner is a property of the id: a cloud conversation the cloud
    /// inbox no longer lists still routes to the cloud (which refuses what
    /// the account may not do), never to the local daemon.
    @Test func aConversationTheCloudInboxDropsStillReachesTheCloud() async throws {
        let (router, local, daemon, cloud) = await router()
        let tape = await EventTape(router)
        #expect(await tape.wait { $0.contains { if case .conversationChanged(let summary, stream: .inbox, rev: _) = $0 { summary.id.rawValue == dm } else { false } } })
        daemon.script.withLock { $0.entries = [] }
        cloud.handle(.inboxReset(seq: 9))
        #expect(await tape.wait { $0.contains(where: { if case .conversationRemoved(let id, _) = $0 { id.rawValue == dm } else { false } }) })
        let send = HomeIntent(key: IdempotencyKey("cmk_d"), op: .sendMessage(conversation: ConversationID(dm), parts: [.text("x")]))
        _ = try? await router.submit(send)
        #expect(local.intents.isEmpty, "a cloud conversation's send reached the local daemon")
        // The cloud subscribes it; the edit waits for the socket.
        #expect(await daemon.wait { $0.contains(.subscribe(dm)) })
    }

    /// The store tells the source when a transcript leaves the screen: the
    /// last of its views closing ends the cloud subscription.
    @MainActor @Test func theLastClosedViewOfACloudConversationEndsItsSubscription() async throws {
        let (router, _, daemon, _) = await router()
        let store = HomeStore(source: router)
        store.start()
        #expect(await until { store.summary(ConversationID(dm)) != nil })
        let id = ConversationID(dm)
        await store.open(id)
        await store.open(id)
        #expect(daemon.calls.contains(.subscribe(dm)))
        store.close(id)
        for _ in 0..<1_000 { await Task.yield() }
        #expect(!daemon.calls.contains(.unsubscribe(dm)), "a view still on screen lost its subscription")
        store.close(id)
        #expect(await daemon.wait { $0.contains(.unsubscribe(dm)) })
        // Opened again: it loads and subscribes again.
        await store.open(id)
        #expect(await daemon.wait { $0.filter { $0 == .subscribe(dm) }.count == 2 })
        store.stop()
    }

    /// Yields until `condition` holds; the suite's time limit bounds it.
    @MainActor func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    /// A cloud conversation opened before the merged inbox loads (a deep
    /// link or a notification) reaches the cloud, not the local daemon.
    @Test func aCloudConversationOpenedBeforeTheInboxLoadsReachesTheCloud() async throws {
        let other = "conv_dm_01J0000000000000000000000E"
        let local = FakeLocalHomeSource()
        let daemon = FakeCloudDaemon(.init(entries: [F.entry(dm), F.entry(other)], heads: [dm: F.head(dm), other: F.head(other)]))
        let cloud = CloudHomeSource(me: local.me)
        let router = HomeSourceRouter(local: local, cloud: cloud)
        cloud.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: F.identity)
        let page = try await router.snapshot(of: ConversationID(dm), tail: 10)
        #expect(page.conversation.owner == .cloud)
        let send = HomeIntent(key: IdempotencyKey("cmk_u"), op: .sendMessage(conversation: ConversationID(other), parts: [.text("x")]))
        // Not open yet: the cloud subscribes it, and the edit waits until its socket is live.
        await #expect(throws: HomeRejection.ownerUnreachable) { try await router.submit(send) }
        #expect(await daemon.wait { $0.contains(.subscribe(other)) })
        #expect(local.intents.isEmpty)
    }
}
