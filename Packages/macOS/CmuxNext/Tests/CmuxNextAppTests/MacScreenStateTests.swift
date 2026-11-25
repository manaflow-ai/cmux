@testable import CmuxNextMacScreen
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

// `mac_screen.state` (`cmux app mac-screens`, every build): each Mac Screen device tab's phase,
// time to first frame, fps, round trips and dropped frames, read-only and bounded.

nonisolated private let deviceID = "0b6c1a2e-3d4f-4a5b-8c9d-aabbccddee01"

struct MacScreenRollingSamplesTests {
    /// The window keeps only its last `capacity` samples, and reads nearest-rank percentiles.
    @Test func theWindowIsBoundedAndReadsPercentiles() throws {
        var samples = MacScreenRollingSamples(capacity: 4)
        #expect(samples.summary == nil)
        for value in [100.0, 1, 2, 3, 4] { samples.add(value) }
        #expect(samples.count == 4, "the oldest (100) is overwritten")
        let summary = try #require(samples.summary)
        #expect(summary == MacScreenRollingSamples.Summary(count: 4, p50: 2, p95: 4, max: 4))
        samples.add(.nan)
        #expect(samples.count == 4)
        for value in 0 ..< 1000 { samples.add(Double(value)) }
        #expect(samples.count == 4 && samples.summary?.max == 999 && samples.summary?.p50 == 997)
    }
}

struct MacScreenFrameTimingsTests {
    /// Frames as they reach the presenter: the first one's time, their intervals, decoded to
    /// shown, and the frames the other Mac numbered that never showed here.
    @Test func framesGiveIntervalsPresentTimesAndDrops() throws {
        var timings = MacScreenFrameTimings()
        let start = ContinuousClock.now
        let ms: UInt64 = 1_000_000
        timings.presented(frame: 1, decodedAtNanos: 1000 * ms, nowNanos: 1002 * ms, now: start)
        timings.presented(frame: 2, decodedAtNanos: 1017 * ms, nowNanos: 1018 * ms, now: start + .milliseconds(16))
        timings.presented(frame: 5, decodedAtNanos: 1030 * ms, nowNanos: 1034 * ms, now: start + .milliseconds(32))
        // The host started over (a new numbering): a baseline, not a drop.
        timings.presented(frame: 1, decodedAtNanos: 1049 * ms, nowNanos: 1050 * ms, now: start + .milliseconds(48))
        #expect(timings.total == 4)
        #expect(timings.firstPresentedAt == start)
        #expect(timings.dropped == 2, "frames 3 and 4 never showed")
        #expect(timings.intervals.summary == MacScreenRollingSamples.Summary(count: 3, p50: 16, p95: 16, max: 16))
        #expect(timings.present.summary == MacScreenRollingSamples.Summary(count: 4, p50: 1, p95: 4, max: 4))
    }

    /// The counter the pane's decoder ticks keeps the same timings, at most a window of samples.
    @Test func theCounterStaysBounded() {
        let counter = MacScreenFrameCounter()
        #expect(counter.tick(frame: 1), "the first frame tells the pane")
        for frame in UInt32(2) ... 500 { _ = counter.tick(frame: frame) }
        let timings = counter.timings
        #expect(timings.total == 500 && timings.dropped == 0)
        #expect(timings.intervals.count == MacScreenFrameTimings.window)
    }
}

struct MacScreenConnectTimingsTests {
    /// First frame is connect start to the first frame shown, once per connect; a new connect
    /// starts over.
    @Test func firstFrameCountsOncePerConnect() {
        var timings = MacScreenConnectTimings()
        let start = ContinuousClock.now
        timings.firstFrame(at: start)
        #expect(timings.firstFrameMs == nil, "no connect yet")
        timings.connectStarted(at: Date(timeIntervalSince1970: 1_700_000_000), start)
        timings.firstFrame(at: start - .milliseconds(5))
        #expect(timings.firstFrameMs == nil, "a frame from before this connect is not its first")
        timings.firstFrame(at: start + .milliseconds(287))
        timings.firstFrame(at: start + .milliseconds(900))
        #expect(timings.firstFrameMs == 287)
        timings.sampleRtt(12)
        timings.sampleRtt(nil)
        #expect(timings.rtt.count == 1)
        timings.connectStarted(at: Date(), start + .seconds(5))
        #expect(timings.firstFrameMs == nil && timings.rtt.count == 0)
    }
}

@MainActor
struct MacScreenStateControlTests {
    private func makePages() -> MacScreenPages {
        let file = FileManager.default.temporaryDirectory.appending(path: "mac-screen-\(UUID().uuidString)/mac-screen.json")
        return MacScreenPages(store: MacScreenStore(file: file), work: BackgroundWork())
    }

    private func rows(_ pages: MacScreenPages, tab: String? = nil) throws -> [[String: CmuxNextSettings.JSONValue]] {
        let answer = pages.stateAnswer(tab.map { ["tab": .string($0)] } ?? [:])
        return try #require(answer.objectValue?["tabs"]?.arrayValue).compactMap(\.objectValue)
    }

    /// A device tab reads its device, phase and timings; a home tab is not listed. The first
    /// frame through the pane's own counter sets `first_frame_ms` and `frames_dropped`.
    @Test func aDeviceTabReadsItsPhaseAndFirstFrame() throws {
        let pages = makePages()
        pages.prepare("home", record: MacScreenRecord(macID: nil), byPerson: true)
        _ = pages.makeView(for: "home")
        pages.prepare("a", record: MacScreenRecord(deviceID: deviceID), byPerson: false)
        _ = pages.makeView(for: "a")
        let session = try #require(pages.tab("a")?.pane?.session)

        let idle = try #require(try rows(pages).first)
        #expect(try rows(pages).count == 1, "the home tab is not a screen")
        #expect(idle["tab"]?.stringValue == "a")
        #expect(idle["device_id"]?.stringValue == deviceID)
        #expect(idle["phase"]?.stringValue == "ended")
        #expect(idle["connected"]?.boolValue == false && idle["has_frame"]?.boolValue == false)
        #expect(idle["first_frame_ms"] == CmuxNextSettings.JSONValue.null && idle["connect_started_at"] == CmuxNextSettings.JSONValue.null)
        #expect(idle["frame_interval_ms"] == CmuxNextSettings.JSONValue.null)

        let start = ContinuousClock.now
        session.timings.connectStarted(at: Date(timeIntervalSince1970: 1_700_000_000), start)
        session.timings.sampleRtt(18)
        let counter = MacScreenFrameCounter()
        session.frameCounter = counter
        _ = counter.tick(frame: 1)
        _ = counter.tick(frame: 4)
        session.framesCounted(counter)
        // An old transport's late batch is not this session's.
        session.framesCounted(MacScreenFrameCounter())

        let live = try #require(try rows(pages, tab: "a").first)
        #expect(live["connect_started_at"]?.stringValue == "2023-11-14T22:13:20Z")
        let first = try #require(live["first_frame_ms"]?.doubleValue)
        #expect(first >= 0 && first < 10_000)
        #expect(live["frames_dropped"]?.doubleValue == 2)
        #expect(live["rtt_ms_window"]?.objectValue?["p50"]?.doubleValue == 18)
        #expect(live["frame_interval_ms"]?.objectValue?["count"]?.doubleValue == 1)
        #expect(try rows(pages, tab: "other").isEmpty)
        pages.tabClosed("a")
        pages.tabClosed("home")
    }

    /// The method `cmux app mac-screens` sends is one the app registers in every build.
    @Test func theCLIReadsAReleaseMethod() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 6 { root.deleteLastPathComponent() }
        let source = try String(contentsOf: root.appendingPathComponent("cmux-tui/crates/cmux-tui/src/cli/app.rs"), encoding: .utf8)
        let line = try #require(source.split(separator: "\n").first { $0.contains("const MAC_SCREENS_METHOD: &str = ") })
        let method = try #require(line.split(separator: "\"").dropFirst().first.map(String.init))
        #expect(method == MacScreenPages.releaseMethods.first)
    }
}
