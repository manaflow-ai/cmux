@testable import CmuxNextControl
import CmuxNextCompat
import Dispatch
import Foundation
import Testing

/// The watchdog thread's hang episodes (``HangEpisodeTracker``): plain state driven by hand.
struct HangEpisodeTrackerTests {
    private let second: UInt64 = 1_000_000_000

    @Test func aHangFiresOncePerStallAndReArmsOnlyAfterRecovery() {
        var tracker = HangEpisodeTracker(hangNanos: 2 * second)
        #expect(tracker.observe(beat: 7, busy: true, elapsedNanos: second).isEmpty, "1 s is a stall, not a hang")
        #expect(tracker.observe(beat: 7, busy: true, elapsedNanos: 2 * second) == [.began(beat: 7, elapsedNanos: 2 * second)])
        // The watchdog looks again every threshold while the main thread stays blocked: no second file.
        #expect(tracker.observe(beat: 7, busy: true, elapsedNanos: 2 * second + 50_000_000).isEmpty)
        #expect(tracker.observe(beat: 7, busy: true, elapsedNanos: 3 * second).isEmpty)
        #expect(tracker.openBeat == 7)
        // The main thread answers (its beat moves): the episode ends with the last duration seen.
        #expect(tracker.observe(beat: 8, busy: true, elapsedNanos: 0) == [.ended(beat: 7, lastElapsedNanos: 3 * second)])
        #expect(tracker.openBeat == nil)
        // The next stall past the threshold is a new episode.
        #expect(tracker.observe(beat: 9, busy: true, elapsedNanos: 2 * second) == [.began(beat: 9, elapsedNanos: 2 * second)])
    }

    @Test func theRunLoopSleepingEndsTheEpisode() {
        var tracker = HangEpisodeTracker(hangNanos: 2 * second)
        _ = tracker.observe(beat: 3, busy: true, elapsedNanos: 2 * second)
        #expect(tracker.observe(beat: 3, busy: false, elapsedNanos: 0) == [.ended(beat: 3, lastElapsedNanos: 2 * second)])
        #expect(tracker.observe(beat: 3, busy: false, elapsedNanos: 0).isEmpty)
    }

    @Test func aLongHangReportsCheckpointsAtDoublingDurations() {
        var tracker = HangEpisodeTracker(hangNanos: 2 * second)
        _ = tracker.observe(beat: 1, busy: true, elapsedNanos: 2 * second)
        #expect(tracker.observe(beat: 1, busy: true, elapsedNanos: 3 * second).isEmpty)
        #expect(tracker.observe(beat: 1, busy: true, elapsedNanos: 4 * second) == [.progressed(beat: 1, elapsedNanos: 4 * second)])
        #expect(tracker.observe(beat: 1, busy: true, elapsedNanos: 7 * second).isEmpty)
        #expect(tracker.observe(beat: 1, busy: true, elapsedNanos: 8 * second) == [.progressed(beat: 1, elapsedNanos: 8 * second)])
    }

    @Test func stoppingClosesTheOpenEpisode() {
        var tracker = HangEpisodeTracker(hangNanos: 2 * second)
        #expect(tracker.finish() == nil)
        _ = tracker.observe(beat: 5, busy: true, elapsedNanos: 5 * second)
        #expect(tracker.finish() == .ended(beat: 5, lastElapsedNanos: 5 * second))
        #expect(tracker.finish() == nil)
    }
}

/// Hang files (``HangEpisodeRecorder``) in a scratch folder.
@Suite(.serialized) struct HangEpisodeRecorderTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "hang-episode-tests-\(UUID().uuidString)")
    }

    private func files(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    @Test func writesTheStackWhenTheHangStartsAndTheDurationWhenItEnds() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = HangEpisodeRecorder(directory: directory)
        let stack = Thread.callStackReturnAddresses.map { UInt(truncating: $0) }
        recorder.begin(beat: 4, elapsed: .seconds(2), main: stack, others: [ThreadSample(name: "worker", addresses: stack)])
        recorder.drain()
        let entry = try #require(recorder.entries.first)
        #expect(recorder.entries.count == 1)
        #expect(entry.ongoing)
        #expect(entry.topFrames.count == HangEpisodeRecorder.topFrameCount)
        var text = try String(contentsOf: entry.url, encoding: .utf8)
        #expect(text.contains("state: blocked"))
        #expect(text.contains("duration: at least 2.000 s"))
        #expect(text.contains("main thread (innermost first):"))
        #expect(text.contains("thread worker:"))
        #expect(text.contains("executable: uuid "))

        recorder.update(beat: 4, duration: .milliseconds(3_456), ongoing: false)
        // Another beat's update (an episode that was never opened) changes nothing.
        recorder.update(beat: 99, duration: .seconds(60), ongoing: false)
        recorder.drain()
        text = try String(contentsOf: entry.url, encoding: .utf8)
        #expect(text.contains("state: recovered"))
        #expect(text.contains("duration: 3.456 s"))
        #expect(recorder.entries.first?.duration == .milliseconds(3_456))
        #expect(recorder.entries.first?.ongoing == false)
        #expect(files(in: directory).count == 1, "one file per episode")

        // The next launch lists it from the file.
        let reloaded = HangEpisodeRecorder(directory: directory)
        reloaded.drain()
        let parsed = try #require(reloaded.entries.first)
        #expect(parsed.url == entry.url)
        #expect(parsed.duration == .milliseconds(3_456))
        #expect(!parsed.ongoing)
        #expect(parsed.topFrames == entry.topFrames)
        #expect(abs(parsed.started.timeIntervalSince(entry.started)) < 0.001)
    }

    /// A single stack cannot tell a main thread doing its own work from one waiting on page-ins
    /// or WindowServer (the CEF pump hangs of 2026-10-29 sampled at function entries). The file
    /// says which: main-thread CPU against the hang's length, and the process's page-ins.
    @Test func saysWhetherTheMainThreadWasBusyOrBlocked() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = HangEpisodeRecorder(directory: directory, symbolicate: { $0.map { String($0) } })
        recorder.begin(beat: 2, elapsed: .seconds(2), main: [], others: [],
                       load: HangLoad(mainThreadCPU: .milliseconds(100), pageIns: 812, faults: 30_500))
        recorder.drain()
        let url = try #require(recorder.entries.first?.url)
        var text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("main thread cpu: 0.100 s of 2.000 s (5%): blocked"))
        #expect(text.contains("page-ins: 812, faults: 30500"))

        recorder.update(beat: 2, duration: .milliseconds(2_500), ongoing: false,
                        load: HangLoad(mainThreadCPU: .milliseconds(2_400), pageIns: 900, faults: 31_000))
        recorder.drain()
        text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("main thread cpu: 2.400 s of 2.500 s (96%): busy"))
        #expect(text.contains("page-ins: 900, faults: 31000"))
        #expect(!text.contains("): blocked"))
        // Still parsed by the next launch.
        let reloaded = HangEpisodeRecorder(directory: directory)
        reloaded.drain()
        #expect(reloaded.entries.first?.duration == .milliseconds(2_500))
    }

    @Test func anUnknownLoadSaysSo() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = HangEpisodeRecorder(directory: directory, symbolicate: { $0.map { String($0) } })
        recorder.begin(beat: 1, elapsed: .seconds(2), main: [], others: [], load: HangLoad())
        recorder.drain()
        let text = try String(contentsOf: try #require(recorder.entries.first?.url), encoding: .utf8)
        #expect(text.contains("main thread cpu: unknown"))
        #expect(text.contains("page-ins: unknown"))
    }

    @Test func keepsOnlyTheNewestFiles() {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = HangEpisodeRecorder(directory: directory, maxFiles: 3)
        // Started 50, 40, ... 10 s ago: the last ones are the newest.
        for (index, ago) in [50, 40, 30, 20, 10].enumerated() {
            recorder.begin(beat: UInt64(index), elapsed: .seconds(ago), main: [], others: [])
            recorder.update(beat: UInt64(index), duration: .seconds(ago), ongoing: false)
        }
        recorder.drain()
        let names = files(in: directory)
        #expect(names.count == 3)
        #expect(recorder.entries.count == 3)
        #expect(recorder.entries.map(\.duration) == [.seconds(10), .seconds(20), .seconds(30)])
        #expect(Set(recorder.entries.map(\.url.lastPathComponent)) == Set(names))
    }

    @Test func capsEachFile() throws {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = HangEpisodeRecorder(directory: directory, maxBytes: 2_048)
        let stack = Thread.callStackReturnAddresses.map { UInt(truncating: $0) }
        let others = (0..<50).map { ThreadSample(name: "thread-\($0)", addresses: stack) }
        recorder.begin(beat: 1, elapsed: .seconds(2), main: stack, others: others)
        recorder.drain()
        let url = try #require(recorder.entries.first?.url)
        let data = try Data(contentsOf: url)
        #expect(data.count <= 2_048)
        #expect(String(decoding: data, as: UTF8.self).hasSuffix("truncated to 2048 bytes\n"))
    }

    /// Symbolication (`dladdr`, the loader lock) can block forever in a hang; the raw stack is on
    /// disk first and the final duration still lands.
    @Test func aStuckSymbolicatorDelaysNeitherTheFileNorItsFinalDuration() throws {
        let directory = scratch()
        let release = DispatchSemaphore(value: 0)
        let recorder = HangEpisodeRecorder(directory: directory, symbolicate: { addresses in
            // concurrency-allow: the recorder's symbol queue in a test, never the main thread; released below.
            release.wait()
            return addresses.map { _ in "symbolicated" }
        })
        defer {
            release.signal()
            recorder.drain()
            try? FileManager.default.removeItem(at: directory)
        }
        recorder.begin(beat: 2, elapsed: .seconds(2), main: [0x1234, 0x5678], others: [])
        recorder.update(beat: 2, duration: .milliseconds(2_500), ongoing: false)
        recorder.drain(symbols: false)
        let url = try #require(recorder.entries.first?.url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("  0  0x1234\n  1  0x5678\n"), "raw addresses: \(text)")
        #expect(text.contains("state: recovered"))
        #expect(text.contains("duration: 2.500 s"))
        #expect(text.contains("load address 0x"))
        #expect(recorder.entries.first?.topFrames == ["0x1234", "0x5678"])
    }

    /// Only regular files in the folder are listed or read: a symlink to a hang file elsewhere is
    /// skipped and never followed, and a file over the cap is not read.
    @Test func ignoresSymlinksAndOversizedFiles() throws {
        let directory = scratch()
        let outside = scratch()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let hang = "cmux main-thread hang\nstarted: 2026-10-22T00:42:10.123Z\nduration: 3.000 s\nstate: recovered\n"
        let target = outside.appending(path: "secret.txt")
        try hang.write(to: target, atomically: true, encoding: .utf8)
        let link = directory.appending(path: "hang-2026-10-22T00-42-10.123Z.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let big = directory.appending(path: "hang-2026-10-21T00-00-00.000Z.txt")
        try (hang + String(repeating: "x", count: 4_096)).write(to: big, atomically: true, encoding: .utf8)
        let recorder = HangEpisodeRecorder(directory: directory, maxBytes: 2_048)
        recorder.drain()
        #expect(recorder.entries.isEmpty)
        #expect(recorder.text(of: link) == nil)
        #expect(!recorder.isHangFile(link))
        #expect(recorder.text(of: big) == nil)
        #expect(recorder.text(of: target) == nil, "outside the folder")
    }

    /// A symbolicator stuck on the loader lock holds one job; later hangs still write their raw
    /// files and finalize, and the work waiting for symbols stays bounded by the files kept.
    @Test func aStuckSymbolicatorKeepsPendingWorkBounded() {
        let directory = scratch()
        let release = DispatchSemaphore(value: 0)
        let calls = CallCount()
        let recorder = HangEpisodeRecorder(directory: directory, maxFiles: 3, symbolicate: { addresses in
            calls.value.add(1, ordering: .relaxed)
            // concurrency-allow: the recorder's symbol queue in a test, never the main thread; released below.
            release.wait()
            release.signal()
            return addresses.map { String($0) }
        })
        defer {
            release.signal()
            recorder.drain()
            try? FileManager.default.removeItem(at: directory)
        }
        for beat in 0..<8 {
            recorder.begin(beat: UInt64(beat), elapsed: .seconds(10 * (10 - beat)), main: [0x10, 0x20], others: [])
            recorder.update(beat: UInt64(beat), duration: .seconds(5), ongoing: false)
        }
        recorder.drain(symbols: false)
        let deadline = ContinuousClock.now + .seconds(10)
        while calls.value.load(ordering: .relaxed) == 0, ContinuousClock.now < deadline { usleep(1_000) }
        usleep(50_000) // a second job, if one were queued, would have started by now
        #expect(calls.value.load(ordering: .relaxed) == 1, "one symbolication in flight")
        #expect(recorder.pendingEpisodeCount <= 3)
        #expect(files(in: directory).count == 3)
        #expect(recorder.entries.allSatisfy { !$0.ongoing })
    }

    @Test func writesNothingWhileTurnedOff() {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = HangEpisodeRecorder(directory: directory, isEnabled: { false })
        recorder.begin(beat: 1, elapsed: .seconds(2), main: [], others: [])
        recorder.update(beat: 1, duration: .seconds(3), ongoing: false)
        recorder.drain()
        #expect(recorder.entries.isEmpty)
        #expect(files(in: directory).isEmpty)
    }

    /// Each change of the list reaches the recorder's subscribers on its own (Debug Settings
    /// follows it while the page shows), after the list changed: the first write, the symbols,
    /// and the end. The symbolicator waits for the test, so each change is taken before the next
    /// one happens and none folds into another. A stream whose task is cancelled is forgotten.
    @Test(.timeLimit(.minutes(1))) func eachEpisodeChangeReachesASubscriber() async throws {
        let directory = scratch()
        // A latch: once the test signals, this and every later symbolication runs.
        let symbolsMayRun = DispatchSemaphore(value: 0)
        let recorder = HangEpisodeRecorder(directory: directory, symbolicate: { addresses in
            symbolsMayRun.wait()
            symbolsMayRun.signal()
            return addresses.map { String($0) }
        })
        defer { // on every exit (a failed expectation, the time limit): no symbol queue worker stays blocked
            symbolsMayRun.signal()
            recorder.drain()
            try? FileManager.default.removeItem(at: directory)
        }
        recorder.drain(symbols: false) // the (empty) folder of earlier launches is read: no change
        var changes = recorder.changes().makeAsyncIterator()
        #expect(recorder.subscriberCount == 1)
        #expect(recorder.changeNotificationCount == 0)

        recorder.begin(beat: 1, elapsed: .seconds(2), main: [1, 2], others: [])
        recorder.drain(symbols: false)
        // The stream folds changes not yet taken, so the count shows a change told twice.
        #expect(recorder.changeNotificationCount == 1, "one hang file written told the subscribers \(recorder.changeNotificationCount) times")
        let written = await changes.next() != nil
        #expect(written, "the first write of the hang file reached no subscriber")
        #expect(recorder.entries.count == 1, "the change arrived before the list changed")
        #expect(recorder.entries.first?.ongoing == true)
        #expect(recorder.entries.first?.topFrames == ["0x1", "0x2"], "symbols before the test let them run")

        symbolsMayRun.signal()
        recorder.drain()
        #expect(recorder.changeNotificationCount == 2, "the symbols told the subscribers \(recorder.changeNotificationCount - 1) times")
        let symbolicated = await changes.next() != nil
        #expect(symbolicated, "the symbols reached no subscriber")
        #expect(recorder.entries.first?.topFrames == ["1", "2"])
        #expect(recorder.entries.first?.ongoing == true)

        recorder.update(beat: 1, duration: .seconds(3), ongoing: false)
        recorder.drain()
        #expect(recorder.changeNotificationCount == 3, "the end told the subscribers \(recorder.changeNotificationCount - 2) times")
        let ended = await changes.next() != nil
        #expect(ended, "the end of the hang reached no subscriber")
        #expect(recorder.entries.first?.ongoing == false)

        // The page leaving cancels its watch: the recorder forgets that stream, keeps the others.
        let leaving = recorder.changes()
        #expect(recorder.subscriberCount == 2)
        let watch = Task { for await _ in leaving {} }
        watch.cancel()
        await watch.value
        #expect(recorder.subscriberCount == 1)
    }

    /// A recorder that goes away ends its streams, so a subscriber that does not own it stops
    /// waiting for a change that cannot come (defense: Debug Settings owns its recorder and ends
    /// its stream when its page closes, DebugSettingsHangWatchTests).
    @Test(.timeLimit(.minutes(1))) func aReleasedRecorderEndsItsStreams() async {
        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        var changes: AsyncStream<Void>.Iterator
        weak var released: HangEpisodeRecorder?
        do {
            let recorder = HangEpisodeRecorder(directory: directory, symbolicate: { $0.map { String($0) } })
            recorder.drain() // the queued read of earlier launches holds the recorder until it ran
            changes = recorder.changes().makeAsyncIterator()
            released = recorder
        }
        #expect(released == nil, "the recorder outlived its last reference")
        let element: Void? = await changes.next()
        #expect(element == nil, "the stream did not end with its recorder")
    }
}

/// The exact length of a hang's stall: recorded by the main thread when it ends, kept until
/// its file takes it.
struct HangEpisodeCompletionTests {
    @MainActor
    @Test func aLaterShortStallDoesNotOverwriteTheEpisodesLength() {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false), uptime: clock.read)
        watchdog.heartbeat(.afterWaiting)
        let beat = watchdog.beatSequence.load(ordering: .acquiring)
        clock.advance(by: .seconds(3))
        watchdog.heartbeat(.beforeWaiting) // the hang ends after 3 s
        watchdog.heartbeat(.afterWaiting)
        clock.advance(by: .milliseconds(200))
        watchdog.heartbeat(.beforeWaiting) // a short stall before the watchdog thread looked
        #expect(watchdog.closeEpisode(beat: beat, lastElapsedNanos: 2_000_000_000) == 3_000_000_000)
        #expect(watchdog.closeEpisode(beat: beat, lastElapsedNanos: 2_000_000_000) == 2_000_000_000, "consumed once")
    }

    /// The stall can end between the watchdog deciding it is a hang and opening its episode;
    /// its file still gets the measured length, not the last one the watchdog saw.
    @MainActor
    @Test func aHangThatEndsBeforeItsEpisodeOpensKeepsItsMeasuredLength() {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false), uptime: clock.read)
        watchdog.heartbeat(.afterWaiting)
        let beat = watchdog.beatSequence.load(ordering: .acquiring)
        clock.advance(by: .seconds(3))
        watchdog.heartbeat(.beforeWaiting)
        #expect(watchdog.closeEpisode(beat: beat, lastElapsedNanos: 2_100_000_000) == 3_000_000_000)
    }

    /// The watch loop itself: after a hang, a main thread that stays busy (heartbeats closer
    /// together than the sampling delay, never sleeping) still finalizes the file.
    @MainActor
    @Test func aBusyRecoveryFinalizesTheFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hang-episode-tests-\(UUID().uuidString)")
        let recorder = HangEpisodeRecorder(directory: directory, symbolicate: { $0.map { String($0) } })
        defer {
            recorder.drain()
            try? FileManager.default.removeItem(at: directory)
        }
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false, logStalls: false,
                                                               hangAssertThreshold: nil), uptime: clock.read)
        watchdog.episodes = recorder
        watchdog.heartbeat(.afterWaiting)
        watchdog.running.store(true, ordering: .releasing)
        let thread = Thread { watchdog.watch(sampler: nil) }
        thread.start()
        defer { watchdog.stop() }
        clock.advance(by: .seconds(3))
        var deadline = ContinuousClock.now + .seconds(10)
        while recorder.entries.first?.ongoing != true, ContinuousClock.now < deadline { usleep(5_000) }
        #expect(recorder.entries.first?.ongoing == true, "the hang file was not opened")
        // Recovered, and busy: a heartbeat every 10 ms of the watchdog's clock, never before-waiting.
        deadline = ContinuousClock.now + .seconds(10)
        while recorder.entries.first?.ongoing != false, ContinuousClock.now < deadline {
            watchdog.heartbeat(.beforeSources)
            clock.advance(by: .milliseconds(10))
            usleep(2_000)
        }
        let entry = try #require(recorder.entries.first)
        #expect(!entry.ongoing, "a busy recovery left the file marked blocked")
        #expect(entry.duration == .seconds(3))
        // The live loop measures the load: the stall's own CPU reading and the process's page-ins.
        let text = try String(contentsOf: entry.url, encoding: .utf8)
        #expect(text.contains("main thread cpu: ") && !text.contains("main thread cpu: unknown"), "no CPU reading in the hang file")
        #expect(text.contains("page-ins: ") && !text.contains("page-ins: unknown"), "no page-in reading in the hang file")
    }
}

/// Symbolicator calls (a class: an `Atomic` cannot be captured).
final class CallCount: Sendable {
    let value = Atomic(0)
}
