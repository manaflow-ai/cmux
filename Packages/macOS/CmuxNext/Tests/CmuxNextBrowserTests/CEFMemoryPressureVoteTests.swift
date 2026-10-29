import CmuxNextCompat
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// cmux's vote reaches the fork's `cmux_memory_pressure_vote` through
/// `cmux_shim_memory_pressure_vote` once per change of the coordinator's vote, none (0) when the vote returns
/// to normal, never for a repeated vote, and never before Chromium is ready or once quit began; a vote made
/// before Chromium starts reaches it at the start.
@MainActor
@Suite(.serialized) struct CEFMemoryPressureVoteTests {
    @Test func oneShimCallPerVoteChangeAndNoneWhenTheOverrideClears() throws {
        VoteSpy.reset()
        let source = VoteSource()
        let runtime = try Self.runtime()
        let vote = CEFMemoryPressureVote.sending(to: runtime)
        vote.follow(source)
        #expect(VoteSpy.levels.isEmpty, "Chromium starts with no cmux voter: a vote of none makes no call")

        source.set(.critical)
        #expect(VoteSpy.levels == [2])
        source.set(.critical)
        #expect(VoteSpy.levels == [2], "a repeated vote makes no call")
        source.set(.warning)
        source.set(.normal)
        #expect(VoteSpy.levels == [2, 1, 0], "macOS warning is Chromium's moderate; a cleared override votes none")
    }

    @Test func aVoteBeforeChromiumIsReadyReachesItAtTheStart() throws {
        VoteSpy.reset()
        let source = VoteSource()
        let runtime = try Self.runtime()
        runtime.state = .loading
        let vote = CEFMemoryPressureVote.sending(to: runtime)
        vote.follow(source)
        source.set(.critical)
        #expect(VoteSpy.levels.isEmpty, "no call before Chromium is ready")

        runtime.state = .ready
        vote.chromiumDidStart()
        #expect(VoteSpy.levels == [2])
        vote.chromiumDidStart()
        #expect(VoteSpy.levels == [2, 2], "a new Chromium has no cmux voter: it gets the held vote again")
    }

    @Test func noCallOnceQuitStoppedChromium() throws {
        VoteSpy.reset()
        let source = VoteSource()
        let runtime = try Self.runtime()
        let vote = CEFMemoryPressureVote.sending(to: runtime)
        vote.follow(source)
        runtime.state = .shutDown
        source.set(.critical)
        source.set(.normal)
        #expect(VoteSpy.levels.isEmpty)
    }

    @Test func theChromiumLevelsMatchBaseMemoryPressureLevel() {
        #expect(CEFMemoryPressureVote.chromiumLevel(.normal) == 0)
        #expect(CEFMemoryPressureVote.chromiumLevel(.warning) == 1)
        #expect(CEFMemoryPressureVote.chromiumLevel(.critical) == 2)
    }

    private static func runtime() throws -> CEFRuntime {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-pressure-vote-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime = CEFRuntime(shim: try VoteSpy.library(), storage: CEFProfileStorage(root: root))
        runtime.adopt(stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), waitDeadlines: MainWakeUpQueue(energy: EnergyPolicySource()))
        return runtime
    }
}

/// The coordinator's side as a test drives it: a vote and its change handlers.
@MainActor
private final class VoteSource: MemoryPressureVoteSource {
    private let handlers = MainActorHandlers<MemoryPressureLevel>()
    private(set) var pressureVote: MemoryPressureLevel = .normal

    func set(_ level: MemoryPressureLevel) {
        guard level != pressureVote else { return }
        pressureVote = level
        handlers.call(level)
    }

    func observePressureVote(_ handler: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void)
        -> MainActorHandlerRegistration<MemoryPressureLevel> {
        handlers.add(handler)
    }
}

/// A shim whose `cmux_shim_memory_pressure_vote` records each level (a C function captures nothing).
private nonisolated enum VoteSpy {
    // crash-allow: the serialized suite's main-actor tests and the C stand-in they call run on one thread
    nonisolated(unsafe) static var levels: [Int32] = []

    static func reset() {
        levels = []
    }

    static func library() throws -> CEFShimLibrary {
        let vote: @convention(c) (Int32) -> Int32 = { level in
            VoteSpy.levels.append(level)
            return 1
        }
        let nothing: @convention(c) () -> Int = { 0 }
        return try CEFShimLibrary.resolving { name in
            switch name {
            case "cmux_shim_memory_pressure_vote": unsafeBitCast(vote, to: UnsafeMutableRawPointer.self)
            default: unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self)
            }
        }
    }
}
