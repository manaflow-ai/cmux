import CmuxHomeCore
@testable import CmuxNextHome
@testable import CmuxNextHomeEngine
import Testing

/// A bare launch's Chief page before its Chief's owner answers: the settings card's changes wait
/// for the real Chief and are made on it (never dropped on the provisional one), a page that went
/// first refuses them, and the page shows the Chief the launch will most likely open.
@MainActor @Suite
struct HomeLaunchChiefSettingsTests {
    static let chief = ConversationID("conv_chief")

    @Test func aChangeBeforeTheOwnerAnswersIsMadeOnTheRealChiefOnceItIsNamed() async throws {
        let hold = LaunchChiefHold()
        let provisional = Engine(name: "provisional"), real = Engine(name: "real")
        let named = Named()
        let source = HomeLaunchChiefEngine.source(for: HomeLaunchChiefSource.conversation, own: provisional, hold: hold) {
            named.all.append($0)
            return real
        }
        let change = Task { try await source.set(["model": "claude-sonnet-5-5"]) }
        for _ in 0..<100 { await Task.yield() }
        #expect(provisional.writes.isEmpty)
        #expect(real.writes.isEmpty)
        hold.resolve(Self.chief) { _, _, _ in }
        let after = try await change.value
        #expect(after.model == "claude-sonnet-5-5")
        #expect(real.writes == [["model": "claude-sonnet-5-5"]])
        #expect(provisional.writes.isEmpty)
        #expect(named.all == [Self.chief])
        // Once named, a change goes to the Chief at once.
        _ = try await source.set(["effort": "high"])
        #expect(real.writes.count == 2)
    }

    @Test func aRenameBeforeTheOwnerAnswersWaitsForTheChief() async {
        let hold = LaunchChiefHold()
        let waiting = Task { await hold.resolved() }
        for _ in 0..<100 { await Task.yield() }
        hold.resolve(Self.chief) { _, _, _ in }
        #expect(await waiting.value == Self.chief)
        #expect(await hold.resolved() == Self.chief)
    }

    @Test func aPageThatWentFirstRefusesTheChange() async {
        let hold = LaunchChiefHold()
        let real = Engine(name: "real")
        let source = HomeLaunchChiefEngine.source(for: HomeLaunchChiefSource.conversation, own: Engine(name: "provisional", isLocal: false), hold: hold) { _ in real }
        let change = Task { () -> HomeChiefEngineError? in
            do throws(HomeChiefEngineError) { _ = try await source.set(["model": nil]); return nil } catch { return error }
        }
        for _ in 0..<100 { await Task.yield() }
        hold.cancel()
        #expect(await change.value == .cloudUnreachable)
        #expect(await hold.resolved() == nil)
        #expect(real.writes.isEmpty)
    }

    @Test func theCardReadsTheRealChiefWhenTheProvisionalOneCannotAnswer() async throws {
        let hold = LaunchChiefHold()
        let real = Engine(name: "real")
        real.model = "claude-opus-5-5"
        let source = HomeLaunchChiefEngine.source(for: HomeLaunchChiefSource.conversation, own: Engine(name: "provisional", fails: true), hold: hold) { _ in real }
        let read = Task { try await source.read() }
        for _ in 0..<100 { await Task.yield() }
        hold.resolve(Self.chief) { _, _, _ in }
        #expect(try await read.value.model == "claude-opus-5-5")
    }

    @Test func anyOtherConversationKeepsItsOwnSource() {
        let own = Engine(name: "own")
        let source = HomeLaunchChiefEngine.source(for: Self.chief, own: own, hold: LaunchChiefHold()) { _ in Engine(name: "real") }
        #expect((source as? Engine) === own)
    }

    @Test func thePageGuessesTheChiefTheLaunchWillOpen() {
        // Signed in, Auto, this Mac's Chief not running: the Hosted Chief (the cloud read lists it).
        #expect(HomeLaunchChiefEngine.guessesCloud(signedIn: true, engine: nil, localRunning: false))
        #expect(HomeLaunchChiefEngine.guessesCloud(signedIn: true, engine: "hosted", localRunning: true))
        // Auto while this Mac's Chief runs, or the Engine row on This Mac: this Mac's.
        #expect(!HomeLaunchChiefEngine.guessesCloud(signedIn: true, engine: nil, localRunning: true))
        #expect(!HomeLaunchChiefEngine.guessesCloud(signedIn: true, engine: "local", localRunning: false))
        // Signed out: no cloud Chief to open.
        #expect(!HomeLaunchChiefEngine.guessesCloud(signedIn: false, engine: "hosted", localRunning: false))
    }
}

/// A Chief's engine that records each write.
@MainActor
private final class Engine: HomeChiefEngineSource {
    let name: String
    nonisolated let isLocal: Bool
    let fails: Bool
    var model: String?
    var writes: [[String: String?]] = []
    nonisolated var place: String? { nil }

    init(name: String, isLocal: Bool = true, fails: Bool = false) {
        (self.name, self.isLocal, self.fails) = (name, isLocal, fails)
    }

    nonisolated func read() async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        try await snapshot()
    }

    nonisolated func set(_ fields: [String: String?]) async throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        await write(fields)
        return try await snapshot()
    }

    private func write(_ fields: [String: String?]) {
        writes.append(fields)
        if let model = fields["model"] { self.model = model }
    }

    private func snapshot() throws(HomeChiefEngineError) -> HomeChiefSnapshot {
        if fails { throw .cloudUnreachable }
        return HomeChiefSnapshot(harness: nil, model: model, effort: nil, avatar: nil, turns: [])
    }
}

/// The Chiefs the hold named for the card.
@MainActor
private final class Named {
    var all: [ConversationID] = []
}
