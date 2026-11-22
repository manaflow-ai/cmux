@testable import CmuxHomeCore
import Foundation
import Synchronization
import Testing
@testable import CmuxNextApp

/// A local owner whose connection the test drives.
nonisolated final class SwitchableLocalHomeSource: HomeSource {
    let base = FakeLocalHomeSource()
    private let continuation = Mutex<AsyncStream<HomeEvent>.Continuation?>(nil)

    func events() async -> AsyncStream<HomeEvent> {
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream()
        self.continuation.withLock { $0 = continuation }
        continuation.yield(.connection(.online))
        continuation.yield(.inbox(base.snapshot))
        return stream
    }

    func set(_ connection: HomeConnection) {
        _ = continuation.withLock { $0?.yield(.connection(connection)) }
    }

    func inbox() async throws -> InboxSnapshot { try await base.inbox() }
    func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        try await base.snapshot(of: conversation, tail: tail)
    }
    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] { [] }
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult { try await base.submit(intent) }
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }
    func resolve(_ contact: ContactAddress) async throws -> ContactResolution { .invitable(contact) }
}

/// The local Chief owner coming back while the cloud kept the merged
/// connection online: the store hears `.ownerRecovered` and resends the
/// sends the owner did not answer at once, instead of waiting for a backoff
/// (live incident 2026-10-09: the Chief owner and brain went away briefly
/// while the account was signed in, so the merged state never left online).
@Suite(.timeLimit(.minutes(1))) nonisolated struct HomeSourceRouterRecoveryTests {
    typealias F = CloudFixtures

    @Test func theLocalOwnerComingBackUnderAnOnlineCloudIsARecovery() async throws {
        let dm = "conv_dm_01J0000000000000000000000A"
        let local = SwitchableLocalHomeSource()
        let daemon = FakeCloudDaemon(.init(entries: [F.entry(dm)], heads: [dm: F.head(dm)]))
        let cloud = CloudHomeSource(me: local.base.me)
        let router = HomeSourceRouter(local: local, cloud: cloud)
        cloud.configure(commands: daemon, link: ObjectIdentifier(daemon), identity: F.identity)
        let events = await router.events()
        var iterator = events.makeAsyncIterator()
        // Online (either owner), then the local owner drops and comes back.
        while let event = await iterator.next() {
            if event == .connection(.online) { break }
        }
        // Both owners' first events land (a test-only settle delay).
        try await Task.sleep(for: .milliseconds(300))
        local.set(.offline(since: Date()))
        local.set(.online)
        var recovered = false
        while let event = await iterator.next() {
            if event == .ownerRecovered { recovered = true; break }
        }
        #expect(recovered)
    }
}
