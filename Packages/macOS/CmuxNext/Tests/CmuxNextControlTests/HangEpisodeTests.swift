@testable import CmuxNextControl
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
        #expect(text.contains("executable uuid: "))

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
}
