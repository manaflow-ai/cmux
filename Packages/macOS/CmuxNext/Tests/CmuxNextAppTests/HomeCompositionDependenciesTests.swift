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
        let source = CompositionHomeSource(cloud: cell.cloud)
        let snapshot = try await source.inbox()
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_AUTH_CAPTURE_FIXTURE": "1"]))
        let roster = cell.cloud ? HomeCloudChiefs(hosted: CloudChief(id: "agent_fixture", displayName: "Chief", isDefault: true,
                                                                    mainConversation: source.id.rawValue, rev: 1)) : HomeCloudChiefs()
        let harnesses = cell.harness == "none" ? [:] : ["claude": cell.harness == "signed-in"]
        services.homeComposition = HomeCompositionDependencies(
            source: source, me: snapshot.me.id, user: user, stackProjectID: "fixture-project",
            chiefHome: ChiefHome(root: root, isolated: true), caches: root.appending(path: "caches"),
            cloudChiefs: roster, harnesses: harnesses)
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

/// Existing HomeSource wire values, never a second account or health model.
/// Sendable: the snapshot is immutable, the stream/continuation are Sendable, and
/// the only mutable counter is protected by lock on every read and write.
private nonisolated final class CompositionHomeSource: HomeSource, @unchecked Sendable {
    let id = ConversationID("conv_fixture")
    private let snapshot: InboxSnapshot
    private let stream: AsyncStream<HomeEvent>
    private let continuation: AsyncStream<HomeEvent>.Continuation
    private let lock = NSLock()
    private var sent = 0
    var submissions: Int { lock.withLock { sent } }

    init(cloud: Bool) {
        let me = Participant(id: ParticipantID("user_fixture"), kind: .human, displayName: "A user")
        let chief = Participant(id: ParticipantID("agent_fixture"), kind: .agent, displayName: "Chief", agentClass: .chief)
        let date = Date(timeIntervalSince1970: 1_000)
        snapshot = InboxSnapshot(me: me, conversations: [ConversationSummary(id: id, owner: cloud ? .cloud : .local,
            title: "Chief", participants: [me, chief], createdAt: date, updatedAt: date)], rev: 1)
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
        return HomeOpResult(rev: 1)
    }
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }
    func resolve(_ contact: ContactAddress) async throws -> ContactResolution { .invitable(contact) }
}
#endif
