import CmuxNextCompat
import CmuxNextMetrics
@testable import CmuxNextSignposts
@testable import CmuxNextTrace
import Foundation
import Testing

/// `input.frame.<kind>` and `resize.frame`, driven by synthetic events: each stamp runs from
/// its event's timestamp to the end of its turn's commit, only when the event changed content; a drag and a resize
/// tick count once per frame; a paste or an input method commit inside a key press takes the key's timestamp. The
/// clock is a counter the test moves, starting at 1 s, so an event timestamp of 1.0 is "now".
@MainActor
struct InputFrameSignpostTests {
    /// `CLOCK_UPTIME_RAW` as a counter.
    private nonisolated final class Uptime: Sendable {
        private let nanos = Atomic<UInt64>(1_000_000_000)

        func advance(micros: UInt64) { _ = nanos.wrappingAdd(micros * 1_000, ordering: .relaxed) }

        var clock: TraceClock {
            TraceClock(reader: .init(uptimeNanos: { [self] in nanos.load(ordering: .relaxed) }, continuousNow: { ContinuousClock.now }))
        }
    }

    /// The ring records a runtime publishes while no ring is attached, in order.
    private nonisolated final class Records: Sendable {
        private let records = Mutex<[TraceRuntime.StubRecord]>([])

        var all: [TraceRuntime.StubRecord] { records.withLock { $0 } }

        func append(_ record: TraceRuntime.StubRecord) { records.withLock { $0.append(record) } }
    }

    private struct Rig {
        let frames: InputFrameSignpost
        let store: MetricsStore
        let uptime: Uptime
        let records: Records
        let trace: TraceRuntime
    }

    private static let profile = MetricsProfile(appVersion: "1.0", buildNumber: "1", channel: "dev", osVersion: "26.1.0",
                                                hardwareClass: "Mac16,10",
                                                buildDay: MetricsProfile.Day(year: 2026, month: 10, day: 26))

    /// Stamps on a fresh runtime with a store; `categories` on in its ring.
    private static func rig(_ categories: SignpostCategory..., capacity: Int = 32) -> Rig {
        let records = Records()
        let uptime = Uptime()
        let trace = TraceRuntime(role: .app, clock: uptime.clock, stubRecorder: { records.append($0) })
        trace.setCategoryMask(categories.reduce(UInt64(0)) { $0 | 1 << UInt64($1.traceBit) })
        let store = MetricsStore(role: .app, profile: profile)
        store.attach(to: trace)
        let frames = InputFrameSignpost(trace: trace, clock: uptime.clock, capacity: capacity)
        return Rig(frames: frames, store: store, uptime: uptime, records: records, trace: trace)
    }

    private static func histogram(_ id: HistogramID, in store: MetricsStore) -> MetricsDelta.Histogram? {
        store.delta().histograms.first { $0.name == id.name }
    }

    /// One dispatch of an event of `kind`, stamped at `timestamp`, that changed content or not.
    private static func dispatch(_ frames: InputFrameSignpost, _ kind: InputFrameSignpost.Kind?, at timestamp: TimeInterval,
                                 changed: Bool, during body: () -> Void = {}) {
        let dispatch = frames.willDispatch(kind, eventTimestamp: timestamp)
        body()
        frames.didDispatch(dispatch, changedContent: changed)
    }

    @Test("A click that changed content records input.frame.mouse_down from its timestamp to the commit")
    func aChangingClickRecords() throws {
        let rig = Self.rig()
        Self.dispatch(rig.frames, .mouseDown, at: 0.998, changed: true) // it waited 2 ms in the queue
        rig.uptime.advance(micros: 3_000)
        rig.frames.runLoopReached(.beforeWaiting)
        let sample = try #require(Self.histogram(.inputFrame(.mouseDown), in: rig.store))
        #expect(sample.count == 1 && sample.sum == 5_000)
        #expect(rig.frames.openCount == 0)
    }

    @Test("An event that changed no content is dropped, and a missed commit records nothing")
    func noFrameAndMissedRecordNothing() {
        let rig = Self.rig()
        Self.dispatch(rig.frames, .mouseUp, at: 1, changed: false)
        rig.frames.runLoopReached(.beforeWaiting)
        Self.dispatch(rig.frames, .scroll, at: 1, changed: true)
        rig.uptime.advance(micros: 400_000)
        rig.frames.runLoopReached(.afterWaiting)
        #expect(rig.store.delta().isEmpty)
        #expect(rig.frames.openCount == 0)
    }

    @Test("Each kind records into its own histogram; a key press records no input.frame")
    func kindsRecordTheirHistogram() throws {
        let rig = Self.rig()
        Self.dispatch(rig.frames, .key, at: 1, changed: true)
        Self.dispatch(rig.frames, .scroll, at: 1, changed: true)
        Self.dispatch(rig.frames, .mouseUp, at: 1, changed: true)
        Self.dispatch(rig.frames, nil, at: 1, changed: true)
        rig.uptime.advance(micros: 1_000)
        rig.frames.runLoopReached(.exit)
        let sample1 = try #require(Self.histogram(.inputFrame(.scroll), in: rig.store))
        #expect(sample1.count == 1)
        let sample2 = try #require(Self.histogram(.inputFrame(.mouseUp), in: rig.store))
        #expect(sample2.count == 1)
        #expect(rig.store.delta().histograms.count == 2)
    }

    @Test("Drags coalesce to one stamp per frame: the frame's first, changed when any of them changed content")
    func dragsCoalescePerFrame() throws {
        let rig = Self.rig()
        Self.dispatch(rig.frames, .drag, at: 0.999, changed: false)
        rig.uptime.advance(micros: 500)
        Self.dispatch(rig.frames, .drag, at: 1.0003, changed: true)
        #expect(rig.frames.openCount == 1)
        rig.uptime.advance(micros: 500)
        rig.frames.runLoopReached(.beforeWaiting)
        Self.dispatch(rig.frames, .drag, at: 1.001, changed: true)
        rig.uptime.advance(micros: 2_000)
        rig.frames.runLoopReached(.beforeWaiting)
        let drags = try #require(Self.histogram(.inputFrame(.drag), in: rig.store))
        #expect(drags.count == 2 && drags.sum == 2_000 + 2_000, "first frame from 0.999 s to 1.001 s, then 2 ms")
    }

    @Test("A paste inside a key press takes the key's timestamp, counts as changed and is stamped once")
    func pasteInsideAKeyPressTakesItsTimestamp() throws {
        let rig = Self.rig()
        Self.dispatch(rig.frames, .key, at: 0.996, changed: false) {
            rig.frames.textCommitted(.paste, eventTimestamp: 0)
            rig.frames.textCommitted(.paste, eventTimestamp: 0)
        }
        rig.uptime.advance(micros: 1_000)
        rig.frames.runLoopReached(.beforeWaiting)
        let paste = try #require(Self.histogram(.inputFrame(.paste), in: rig.store))
        #expect(paste.count == 1 && paste.sum == 5_000)
    }

    @Test("An input method commit outside a dispatch uses its event, or now; secure input records none")
    func imeCommitOutsideADispatch() throws {
        let rig = Self.rig()
        rig.frames.textCommitted(.imeCommit, eventTimestamp: 0.999)
        rig.frames.textCommitted(.imeCommit, eventTimestamp: 0)
        rig.uptime.advance(micros: 2_000)
        rig.frames.runLoopReached(.beforeWaiting)
        let commits = try #require(Self.histogram(.inputFrame(.imeCommit), in: rig.store))
        #expect(commits.count == 2 && commits.sum == 3_000 + 2_000)

        rig.trace.setKeyTimingSuppressed(true, by: .secureEventInput)
        rig.frames.textCommitted(.imeCommit, eventTimestamp: 0)
        Self.dispatch(rig.frames, .key, at: 1, changed: true) { rig.frames.textCommitted(.paste, eventTimestamp: 0) }
        #expect(rig.frames.openCount == 0, "secure input stamps no typed text")
    }

    @Test("A commit inside a click's dispatch (a tracking loop) ends its stamp as shown")
    func aCommitInsideTheDispatchShowsIt() throws {
        let rig = Self.rig()
        Self.dispatch(rig.frames, .mouseDown, at: 1, changed: false) {
            rig.uptime.advance(micros: 4_000)
            rig.frames.runLoopReached(.beforeWaiting)
        }
        let sample3 = try #require(Self.histogram(.inputFrame(.mouseDown), in: rig.store))
        #expect(sample3.sum == 4_000)
    }

    @Test("Live-resize ticks record resize.frame once per frame")
    func resizeTicksRecordOncePerFrame() throws {
        let rig = Self.rig()
        rig.frames.resizeTick(eventTimestamp: 0.999)
        rig.frames.resizeTick(eventTimestamp: 1)
        rig.uptime.advance(micros: 7_000)
        rig.frames.runLoopReached(.beforeWaiting)
        rig.frames.resizeTick(eventTimestamp: 0)
        rig.uptime.advance(micros: 1_000)
        rig.frames.runLoopReached(.exit)
        let resize = try #require(Self.histogram(.resizeFrame, in: rig.store))
        #expect(resize.count == 2 && resize.sum == 8_000 + 1_000)
    }

    @Test("A turn holds at most its capacity of stamps")
    func capacityBoundsAStamp() {
        let rig = Self.rig(capacity: 2)
        for _ in 0..<4 { Self.dispatch(rig.frames, .mouseDown, at: 1, changed: true) }
        #expect(rig.frames.openCount == 2)
    }

    @Test("With the category on, a stamp is an AB with its kind and age and an AE with how it ended")
    func ringRecordsDecode() throws {
        let rig = Self.rig(.input, .resize)
        Self.dispatch(rig.frames, .scroll, at: 0.9985, changed: true)
        Self.dispatch(rig.frames, .mouseUp, at: 0, changed: false)
        rig.frames.resizeTick(eventTimestamp: 1)
        rig.frames.runLoopReached(.beforeWaiting)
        let records = rig.records.all
        try #require(records.count == 6)
        #expect(records.map(\.phase) == [.asyncBegin, .asyncBegin, .asyncBegin, .asyncEnd, .asyncEnd, .asyncEnd])
        #expect(records[0].name == SignpostName.inputFrame.rawValue && records[2].name == SignpostName.resizeFrame.rawValue)
        #expect(records[0].arg0 & 0xFF == UInt64(InputFrameSignpost.Kind.scroll.rawValue))
        #expect(records[0].arg0 >> 40 == 1_500, "1.5 ms old at its dispatch")
        #expect(records[1].arg0 >> 40 == 0xFF_FFFF, "no timestamp: no age")
        #expect(records[3].arg1 == records[0].arg1 && records[4].arg1 == records[1].arg1)
        #expect(records[3].arg0 == Signposter.EndCode.ended && records[4].arg0 == Signposter.EndCode.noFrame
            && records[5].arg0 == Signposter.EndCode.ended)
    }

    @Test("With the categories off, stamps write no ring record and still record their histograms")
    func categoryOffWritesNoRecords() throws {
        let rig = Self.rig()
        Self.dispatch(rig.frames, .mouseDown, at: 1, changed: true)
        rig.frames.runLoopReached(.beforeWaiting)
        #expect(rig.records.all.isEmpty)
        let sample4 = try #require(Self.histogram(.inputFrame(.mouseDown), in: rig.store))
        #expect(sample4.count == 1)
    }

    @Test("Nested dispatches restore the outer one: a paste after an inner click still takes the key's timestamp")
    func nestedDispatchRestoresTheOuter() throws {
        let rig = Self.rig()
        Self.dispatch(rig.frames, .key, at: 0.997, changed: false) {
            Self.dispatch(rig.frames, .mouseDown, at: 1, changed: false)
            rig.frames.textCommitted(.paste, eventTimestamp: 0)
        }
        rig.uptime.advance(micros: 1_000)
        rig.frames.runLoopReached(.beforeWaiting)
        let sample5 = try #require(Self.histogram(.inputFrame(.paste), in: rig.store))
        #expect(sample5.sum == 4_000)
    }
}
