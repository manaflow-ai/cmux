import CmuxNextCompat
import CmuxNextSettings
import Foundation
import Testing

/// The notification sound player (https://github.com/manaflow-ai/cmux/issues/55219): a sound cmux
/// keeps in its own folder plays from that file, `notifications.sounds.maxSeconds` stops a sound at
/// its length, 0 lets it play to its end, and the gate hands the player the library's files and the
/// length the person set.
@MainActor
struct NotificationSoundPlayerTests {
    /// A sound that records what the player did to it.
    private final class Recorder: NotificationSoundOutput {
        var volume: Float = 1
        var plays = 0
        var stops = 0
        var stopped: CheckedContinuation<Void, Never>?
        func play() -> Bool { plays += 1; return true }
        func stop() -> Bool {
            stops += 1
            stopped?.resume()
            stopped = nil
            return true
        }
    }

    /// A clock whose sleeps end only when the test fires them, so no deadline depends on the runner.
    private final class HeldClock: Clock, Sendable {
        typealias Instant = ContinuousClock.Instant
        private struct State {
            var sleepers: [CheckedContinuation<Void, any Error>] = []
            var watchers: [CheckedContinuation<Void, Never>] = []
        }
        private let state = Mutex(State())
        var now: Instant { .now }
        var minimumResolution: Duration { .zero }

        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            try await withCheckedThrowingContinuation { (sleeper: CheckedContinuation<Void, any Error>) in
                let watchers = state.withLock { state in
                    state.sleepers.append(sleeper)
                    defer { state.watchers = [] }
                    return state.watchers
                }
                for watcher in watchers { watcher.resume() }
            }
        }

        /// Returns once a deadline is asleep on the clock.
        func waitForSleeper() async {
            await withCheckedContinuation { (watcher: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state in
                    if !state.sleepers.isEmpty { return true }
                    state.watchers.append(watcher)
                    return false
                }
                if ready { watcher.resume() }
            }
        }

        /// Ends every sleep (a deadline a replay replaced wakes and does nothing).
        func fire() {
            for sleeper in state.withLock({ state in defer { state.sleepers = [] }; return state.sleepers }) { sleeper.resume() }
        }
    }

    private let clock = HeldClock()

    private func player() -> (NotificationSoundPlayer, () -> [String: Recorder], () -> [(name: String, file: URL?)]) {
        final class Box { var sounds: [String: Recorder] = [:]; var loaded: [(name: String, file: URL?)] = [] }
        let box = Box()
        let player = NotificationSoundPlayer(clock: clock) { name, file in
            box.loaded.append((name, file))
            let sound = Recorder()
            box.sounds[name] = sound
            return sound
        }
        return (player, { box.sounds }, { box.loaded })
    }

    private static func stop(_ sound: Recorder) async {
        await withCheckedContinuation { sound.stopped = $0 }
    }

    @Test func aKeptSoundPlaysFromItsFileAndStopsAtItsLength() async throws {
        let (player, sounds, loaded) = player()
        let file = URL(fileURLWithPath: "/tmp/cmux-sounds/My Chime.m4a")
        player.use(files: ["My Chime": file], maxSeconds: 2)
        player.play("My Chime", volume: 0.5, banner: true)
        #expect(loaded().map(\.file) == [file], "a kept sound loads from its file, not by a system name")
        let chime = try #require(sounds()["My Chime"])
        #expect(chime.plays == 1 && chime.volume == 0.5)
        let stopsBefore = chime.stops
        await clock.waitForSleeper()
        clock.fire()
        await Self.stop(chime)
        #expect(chime.stops == stopsBefore + 1, "the sound stops at notifications.sounds.maxSeconds")

        player.play("Glass", volume: 1, banner: false)
        #expect(loaded().last?.name == "Glass" && loaded().last?.file == nil, "a system sound still loads by name")
    }

    @Test func zeroPlaysEachSoundToItsEnd() async throws {
        let (player, sounds, _) = player()
        player.use(files: [:], maxSeconds: 0)
        player.play("Glass", volume: 1, banner: false)
        let glass = try #require(sounds()["Glass"])
        let glassStops = glass.stops
        // A later sound with a length proves the clock: only its deadline sleeps and fires.
        player.use(files: [:], maxSeconds: 1)
        player.play("Pop", volume: 1, banner: false)
        let pop = try #require(sounds()["Pop"])
        await clock.waitForSleeper()
        clock.fire()
        await Self.stop(pop)
        #expect(glass.stops == glassStops, "with no length Glass was never cut")
    }

    @Test func theGateHandsThePlayerTheLibrarysFilesAndTheLength() throws {
        @MainActor final class Spy: NotificationSoundPlaying {
            var used: [(files: [String: URL], maxSeconds: Double)] = []
            func play(_ name: String, volume: Double, banner: Bool) {}
            func use(files: [String: URL], maxSeconds: Double) { used.append((files, maxSeconds)) }
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "notification-gate-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appending(path: "Sounds", directoryHint: .isDirectory)
        let library = NotificationSoundLibrary(userDirectory: kept, otherDirectories: [])
        let source = root.appending(path: "Ding.wav")
        try Data("ding".utf8).write(to: source)
        #expect(try library.importSound(from: source) == "Ding")

        let spy = Spy()
        let gate = NotificationSoundGate(player: spy, library: library)
        var prefs = NotificationSoundPreferences()
        prefs.maxSeconds = 4
        gate.apply(prefs)
        gate.take(names: library.names(), files: library.customFiles())
        #expect(gate.soundNames == ["Ding"])
        #expect(spy.used.last?.files == ["Ding": kept.appending(path: "Ding.wav")])
        #expect(spy.used.last?.maxSeconds == 4)
    }
}
