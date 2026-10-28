#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextCloud
@testable import CmuxNextHome
import CmuxNextHomeEngine
import CmuxNextHostedChief
import Testing

/// Composition coverage, not sign-in or cloud transport coverage. Running these with
/// AppServices requires the auth-capture fixture so no ambient account is consulted.
@MainActor @Suite(.serialized)
struct HomeCompositionDependenciesTests {
    struct Case: Sendable {
        let signedIn: Bool
        let cloud: Bool
        let harness: String
        static let all: [Case] = [false, true].flatMap { signedIn in
            [false, true].flatMap { cloud in
                ["none", "signed-out", "signed-in"].map { Case(signedIn: signedIn, cloud: cloud, harness: $0) }
            }
        }
    }

    @Test(arguments: Case.all)
    func actualHomeCompositionConsumesTheInjectedInputs(_ cell: Case) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appending(path: "home-composition-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let user = cell.signedIn ? CMUXAuthUser(id: "fixture-user", primaryEmail: "fixture@example.invalid", displayName: "A user") : nil
        let source = try await CompositionHomeSource(cloud: cell.cloud)
        let snapshot = try await source.inbox()
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_AUTH_CAPTURE_FIXTURE": "1"]))
        let roster = cell.cloud ? HomeCloudChiefs(hosted: CloudChief(id: "agent_chief", displayName: "Chief", isDefault: true,
                                                                    mainConversation: source.id.rawValue, rev: 1)) : HomeCloudChiefs()
        let harnesses = cell.harness == "none" ? [:] : ["claude": cell.harness == "signed-in"]
        services.homeComposition = (HomeCompositionDependencies(
            source: source, me: snapshot.me.id, user: user, stackProjectID: "fixture-project",
            chiefHome: ChiefHome(root: root, isolated: true), caches: root.appending(path: "caches"),
            harnesses: harnesses), roster)
        let home = services.home
        #expect(home.chief.home.root == root)
        #expect(home.chief.home.isolated)
        #expect(home.pinAccount == (user.map { CloudIdentity.workerUserID(stackProjectID: "fixture-project", stackUserID: $0.id) } ?? "local"))
        #expect(home.cloudChiefs == roster)
        #expect(await home.listedHarnesses() == harnesses.keys.sorted())
        #expect(await home.checkHarness("claude") == (cell.harness == "signed-in"))
        #expect(await home.checkHarness("missing") == false)

        // Use HomeService's real store. A second standalone store would miss the injection.
        let store = home.homeStore
        store.start()
        let view = HomeNativeTranscriptView(store: store, conversation: source.id, me: home.compositionParticipant)
        defer { view.stop(); store.stop(); source.finish() }
        await view.binding.opened()
        try await settle { store.me != nil && store.summary(source.id) != nil }
        view.setFirstRunStarters(HomeStarterContext())
        view.frame = NSRect(x: 0, y: 0, width: 460, height: 760)
        view.layoutSubtreeIfNeeded()
        #expect(store.summary(source.id)?.owner == (cell.cloud ? .cloud : .local))
        #expect(store.me?.id == snapshot.me.id)
        #expect(!view.firstRun.isHidden)
        #expect(view.firstRun.starters.buttons.map(\.title) == HomeStarterContext().prompts)
        #expect(view.firstRun.actionRows.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
        #expect(home.isCloudConversation(source.id) == cell.cloud)

        // The actual store refuses an offline owner, then accepts the same op after recovery.
        source.publish(.connection(.offline(since: Date(timeIntervalSince1970: 0))))
        try await settle { !store.isOnline }
        await #expect(throws: HomeRejection.ownerUnreachable) {
            try await store.perform(.setTyping(conversation: source.id, on: true))
        }
        #expect(source.submissions == 0)
        source.publish(.connection(.online))
        try await settle { store.isOnline }
        _ = try await store.perform(.setTyping(conversation: source.id, on: true))
        #expect(source.submissions == 1)
    }

    private func settle(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition(), "Home store did not apply the fixture's event before the deadline")
    }
}

/// The existing in-memory owner supplies the ledger and participant identity. This wrapper
/// only empties its initial Chief and changes the declared local/cloud owner for composition.
/// Sendable: the snapshot is immutable, the stream/continuation are Sendable, and
/// the only mutable counter is protected by lock on every read and write.
private nonisolated final class CompositionHomeSource: HomeSource, @unchecked Sendable {
    let id = ConversationID("conv_chief")
    private let base = MockHomeSource(options: .init(chiefHistory: 1, latency: .zero, replyDelay: .zero))
    private let snapshot: InboxSnapshot
    private let stream: AsyncStream<HomeEvent>
    private let continuation: AsyncStream<HomeEvent>.Continuation
    private let lock = NSLock()
    private var sent = 0
    var submissions: Int { lock.withLock { sent } }

    init(cloud: Bool) async throws {
        var inbox = try await base.inbox()
        inbox.conversations = inbox.conversations.filter { $0.id == id }
        for index in inbox.conversations.indices {
            inbox.conversations[index].owner = cloud ? .cloud : .local
            inbox.conversations[index].lastSeq = 0
            inbox.conversations[index].lastMessage = nil
        }
        snapshot = inbox
        (stream, continuation) = AsyncStream.makeStream()
        continuation.yield(.connection(.online))
        continuation.yield(.inbox(snapshot))
    }

    func publish(_ event: HomeEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }
    func events() async -> AsyncStream<HomeEvent> { stream }
    func inbox() async throws -> InboxSnapshot { snapshot }
    func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        guard let summary = snapshot.conversations.first(where: { $0.id == conversation }) else { throw HomeRejection.notAuthorized }
        return ConversationPage(conversation: summary, messages: [])
    }
    func history(of conversation: ConversationID, before seq: Seq, limit: Int) async throws -> [Message] { [] }
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        if case .setTyping = intent.op { lock.withLock { sent += 1 } }
        return try await base.submit(intent)
    }
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }
    func resolve(_ contact: ContactAddress) async throws -> ContactResolution { try await base.resolve(contact) }
}
#endif
