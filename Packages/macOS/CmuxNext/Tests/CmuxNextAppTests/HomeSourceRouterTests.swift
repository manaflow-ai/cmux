import CmuxHomeCore
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
        ConversationPage(conversation: snapshot.conversations[0], messages: [])
    }
    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] { [] }
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        submitted.withLock { $0.append(intent) }
        if case .createChief = intent.op { throw HomeRejection.invalid("unsupported_on_local_owner") }
        return HomeOpResult(rev: 2, conversation: intent.op.conversation)
    }
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }
    func resolve(_ contact: ContactAddress) async throws -> ContactResolution { .invitable(contact) }
}

/// One Home inbox over the local and the cloud owners
/// (home-cloud-proxy.md part 2): each conversation's reads and ops reach its
/// own owner, and local behavior is unchanged.
@Suite(.timeLimit(.minutes(1))) struct HomeSourceRouterTests {
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
        cloud.handle(.inboxChanged(CloudInboxChanged(seq: 5, entries: [F.entry(dm, rev: 3, pinned: true)])))
        cloud.handle(.inboxChanged(CloudInboxChanged(seq: 6, entries: [F.entry(dm, archived: true)])))
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
}
