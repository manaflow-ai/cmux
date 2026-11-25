@testable import CmuxNextMacScreen
import CmuxNextRemoteView
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

    /// A frame on the glass gives the viewer's Decode (release to decoded), Present (decoded to
    /// the glass) and their sum; times out of order (another clock) are left out.
    @Test func shownFramesGiveDecodeAndPresentStages() throws {
        var timings = MacScreenFrameTimings()
        let ms: UInt64 = 1_000_000
        let now = ContinuousClock.now
        for (frame, released, decoded) in [(UInt32(1), 100 * ms, 103 * ms), (2, 200 * ms, 202 * ms), (3, 0, 302 * ms), (4, 403 * ms, 402 * ms)] {
            timings.presented(frame: frame, releasedAtNanos: released, decodedAtNanos: decoded, nowNanos: decoded, now: now)
        }
        timings.shown(RemoteViewerFrameTimes(frame: 1, releasedAtNanos: 100 * ms, decodedAtNanos: 103 * ms, presentedAtNanos: 111 * ms))
        timings.shown(RemoteViewerFrameTimes(frame: 2, releasedAtNanos: 200 * ms, decodedAtNanos: 202 * ms, presentedAtNanos: 206 * ms))
        timings.shown(RemoteViewerFrameTimes(frame: 3, releasedAtNanos: 0, decodedAtNanos: 302 * ms, presentedAtNanos: 306 * ms))
        timings.shown(RemoteViewerFrameTimes(frame: 4, releasedAtNanos: 400 * ms, decodedAtNanos: 402 * ms, presentedAtNanos: 401 * ms))
        #expect(timings.decode.summary == MacScreenRollingSamples.Summary(count: 2, p50: 2, p95: 3, max: 3))
        #expect(timings.glass.summary == MacScreenRollingSamples.Summary(count: 2, p50: 4, p95: 8, max: 8))
        #expect(timings.decodePresent.summary == MacScreenRollingSamples.Summary(count: 2, p50: 6, p95: 11, max: 11))
    }

    /// A static screen sends one keyframe. Decode has its value at decode time, before any
    /// presented handler runs; a presented time of 0 (macOS recorded none) takes the handler's
    /// own time, a real one is used as is, so Present and Decode + Present get a value either way.
    @Test func oneKeyframeGivesEveryStageWithOrWithoutAPresentedTime() throws {
        let ms: UInt64 = 1_000_000
        for presentedAtMicros: UInt64 in [0, 30_000] {
            let counter = MacScreenFrameCounter()
            _ = counter.tick(frame: 1, releasedAtNanos: 20 * ms, decodedAtNanos: 24 * ms)
            #expect(counter.timings.decode.summary?.p50 == 4, "decode is known before the frame is shown")
            #expect(counter.timings.glass.summary == nil)
            let times = RemoteViewerFrameTimes.shown(frame: 1, releasedAtNanos: 20 * ms, decodedAtNanos: 24 * ms,
                                                     presentedAtMicros: presentedAtMicros, nowNanos: 29 * ms)
            #expect(times.presentedAtNanos == (presentedAtMicros > 0 ? 30 * ms : 29 * ms))
            counter.shown(times)
            let timings = counter.timings
            #expect(timings.decode.count == 1)
            #expect(timings.glass.summary?.p50 == (presentedAtMicros > 0 ? 6 : 5))
            #expect(timings.decodePresent.summary?.p50 == (presentedAtMicros > 0 ? 10 : 9))
        }
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

struct MacScreenHelperNoAnswerTests {
    /// A helper that would not start, one ended at its deadline, one that exited and one killed
    /// by a signal each say so in their own words; none reads as a grant that is off.
    @Test func eachWayTheHelperGivesNoGrantsHasItsOwnWords() {
        let causes: [MacScreenHelper.NoAnswer] = [.didNotStart("spawn failed"), .timedOut, .exited(status: 3 << 8), .exited(status: 9)]
        let words = causes.map(\.reason)
        #expect(Set(words).count == causes.count)
        #expect(words[0].contains("did not start: spawn failed"))
        #expect(words[1].contains("within 10 seconds"))
        #expect(words[2].contains("exited (status 3)"))
        #expect(words[3].contains("signal 9"))
        #expect(words.allSatisfy { !$0.contains("not granted") })
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

    /// Each stage ends once, when the connect first gets past it; a skipped stage ends with the later one.
    @Test func eachConnectStageEndsOnce() {
        var timings = MacScreenConnectTimings()
        let start = ContinuousClock.now
        timings.reached(.link, at: start)
        #expect(timings.stageMs.isEmpty, "no connect yet")
        timings.connectStarted(at: Date(), start)
        timings.reached(.link, at: start + .milliseconds(120))
        timings.reached(.link, at: start + .milliseconds(400))
        timings.reached(.shown, at: start + .milliseconds(510))
        #expect(timings.stageMs == [.answer: 120, .link: 510, .frame: 510])
        timings.connectStarted(at: Date(), start + .seconds(5))
        #expect(timings.stageMs.isEmpty)
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
        // Opened by automation that waits for the person: the Connect card, no stream started yet.
        #expect(idle["phase"] == CmuxNextSettings.JSONValue.null)
        #expect(idle["hub_phase"]?.stringValue == "idle" && idle["state"]?.stringValue == "idle")
        #expect(idle["started_by"] == CmuxNextSettings.JSONValue.null)
        #expect(idle["connected"]?.boolValue == false && idle["has_frame"]?.boolValue == false)
        #expect(idle["first_frame_ms"] == CmuxNextSettings.JSONValue.null && idle["connect_started_at"] == CmuxNextSettings.JSONValue.null)
        #expect(idle["frame_interval_ms"] == CmuxNextSettings.JSONValue.null)
        // Nothing asked the hub: the read says so, rather than only "ended" and "no_answer".
        #expect(idle["hub_phase"]?.stringValue == "idle")
        #expect(idle["waits_to_show"]?.boolValue == false)

        let start = ContinuousClock.now
        session.timings.connectStarted(at: Date(timeIntervalSince1970: 1_700_000_000), start)
        session.timings.sampleRtt(18)
        let counter = MacScreenFrameCounter()
        session.frameCounter = counter
        let ms: UInt64 = 1_000_000
        _ = counter.tick(frame: 1)
        _ = counter.tick(frame: 4, releasedAtNanos: 10 * ms, decodedAtNanos: 13 * ms)
        counter.shown(RemoteViewerFrameTimes(frame: 4, releasedAtNanos: 10 * ms, decodedAtNanos: 13 * ms, presentedAtNanos: 21 * ms))
        session.framesCounted(counter)
        // An old transport's late batch is not this session's.
        session.framesCounted(MacScreenFrameCounter())
        // The host answered, the link came up, a picture showed.
        session.reach(.link)
        session.reach(.frame)
        session.framePresented(size: CGSize(width: 1920, height: 1080))

        let live = try #require(try rows(pages, tab: "a").first)
        #expect(live["phase"]?.stringValue == "ended", "a connect began: the phase is the session's")
        #expect(live["connect_started_at"]?.stringValue == "2023-11-14T22:13:20Z")
        // A picture showed: the read names the stage it reached and when each stage before it ended.
        #expect(live["connect_stage"]?.stringValue == "shown")
        let stages = try #require(live["connect_stage_ms"]?.objectValue)
        #expect(Set(stages.keys) == ["answer", "link", "frame"])
        let answer = try #require(stages["answer"]?.doubleValue)
        let link = try #require(stages["link"]?.doubleValue)
        let frame = try #require(stages["frame"]?.doubleValue)
        #expect(answer <= link && link <= frame && frame < 10_000)
        let first = try #require(live["first_frame_ms"]?.doubleValue)
        #expect(first >= 0 && first < 10_000)
        #expect(live["frames_dropped"]?.doubleValue == 2)
        #expect(live["rtt_ms_window"]?.objectValue?["p50"]?.doubleValue == 18)
        #expect(live["frame_interval_ms"]?.objectValue?["count"]?.doubleValue == 1)
        #expect(live["decode_ms"]?.objectValue?["p50"]?.doubleValue == 3)
        #expect(live["glass_ms"]?.objectValue?["p50"]?.doubleValue == 8)
        #expect(live["decode_present_ms"]?.objectValue?["p50"]?.doubleValue == 11)
        #expect(try rows(pages, tab: "other").isEmpty)
        pages.tabClosed("a")
        pages.tabClosed("home")
    }

    /// A device tab holding a scope until it is shown (`macScreen.open --autoconnect` into a tab that
    /// was never selected) reads `waits_to_show`, and the hub request it then makes reads its phase.
    @Test func aTabThatWaitsToBeShownSaysSo() throws {
        let pages = makePages()
        _ = pages.record(forDevice: deviceID, requesting: .view)
        pages.prepare("a", record: MacScreenRecord(deviceID: deviceID), byPerson: true)
        _ = pages.makeView(for: "a")
        let waiting = try #require(try rows(pages, tab: "a").first)
        #expect(waiting["hub_phase"]?.stringValue == "idle")
        #expect(waiting["waits_to_show"]?.boolValue == true)
        // Shown: the scope goes to the hub (with no hub signed in here, it is refused at once).
        try #require(pages.tab("a")?.pane).resume()
        let asked = try #require(try rows(pages, tab: "a").first)
        #expect(asked["hub_phase"]?.stringValue == "refused")
        #expect(asked["waits_to_show"]?.boolValue == false)
        pages.tabClosed("a")
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
