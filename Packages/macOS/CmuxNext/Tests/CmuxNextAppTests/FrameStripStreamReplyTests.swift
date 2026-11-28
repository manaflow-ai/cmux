#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextDesign
import CmuxNextSettings
import Testing

/// The frame strip's reply with the recorder's counts of its stream (`screen_stream`, ``StreamTally``). The app puts a
/// recording's fields into the reply only when ALL of them convert to the reply's values (`JSONValue(foundation:)`
/// in `DebugFrameStrip`): one value that does not convert would take `capture` out of the reply too, and the reader
/// of the frames then judges no recording. No stream runs here: each tally gets its buffers by hand.
///
/// The reader's test of the same reply is `test_the_reply_that_the_apps_own_test_wants_has_counts_that_agree` in
/// `scripts/cmux-next/tests/test_new_surface_frames.py`: it has the `screen_stream` of the first test here, number
/// for number, kept the same by hand. Change the 2 together.
struct FrameStripStreamReplyTests {
    @Test func aTallyWithAValueInEachFieldGoesThroughTheReplysConversion() {
        var tally = StreamTally()
        // 7 buffers, the key at 100 ms: 2 with no row before the first picture, 3 rows, 2 with no row after them.
        // A buffer with no row says if its time is the handler's own (1) or the display's (0).
        tally.noRow(at: 90, why: StreamTally.noStatus, own: true)
        tally.noRow(at: 95, why: StreamTally.idleBeforeAPicture, own: false)
        tally.row("c", index: 0, at: 100.04, time: .display(age: 3.26), work: 1.24)
        tally.row("i", index: 1, at: 108.4, time: .missing, work: 0)
        tally.row("c", index: 2, at: 116.7, time: .later, work: 2)
        tally.noRow(at: 118, why: StreamTally.noPicture, own: StreamTally.Time.later.isOwn)
        tally.noRow(at: 120, why: 2, own: StreamTally.Time.display(age: 1).isOwn)
        let fields = FrameStripRecording.fields(capture: .screenCaptureKit, error: nil, stream: tally, sentAt: 100)
        let stream: JSONValue = .object([
            "buffers": .number(7), "rows": .number(3), "row_status": .string("cic"),
            "complete": .number(3), "idle": .number(2), "other_status": .object(["2": .number(1)]),
            "no_status": .number(1), "no_picture": .number(1), "idle_before_a_picture": .number(1),
            "own_time_rows": .array([.number(1), .number(2)]), "no_display_time": .number(1), "display_time_later": .number(1),
            "no_row": .array([.array([.number(-10), .number(-1), .number(1)]), .array([.number(-5), .number(-3), .number(0)]),
                              .array([.number(18), .number(-2), .number(1)]), .array([.number(20), .number(2), .number(0)])]),
            "row_ms": .array([.number(0), .number(8.4), .number(16.7)]),
            "lag_ms_max": .number(3.3), "lag_ms_mean": .number(3.3), "work_ms_max": .number(2), "work_ms_mean": .number(1.6),
        ])
        #expect(JSONValue(foundation: fields) == .object(["capture": .string("screencapturekit"), "lead_ms": .number(100), "screen_stream": stream]),
                "nil: one value of the recording's fields does not convert, and the reply then has no `capture`")
    }

    /// The common form: each buffer made a row with the display's time, so 3 collections of the reply are empty.
    @Test func aTallyWithRowsOnlyGoesThroughTheReplysConversion() {
        var tally = StreamTally()
        tally.row("c", index: 0, at: 100, time: .display(age: 2), work: 1)
        tally.row("i", index: 1, at: 108.3, time: .display(age: 1), work: 0)
        let fields = FrameStripRecording.fields(capture: .screenCaptureKit, error: nil, stream: tally, sentAt: 100)
        let stream: JSONValue = .object([
            "buffers": .number(2), "rows": .number(2), "row_status": .string("ci"),
            "complete": .number(1), "idle": .number(1), "other_status": .object([:]),
            "no_status": .number(0), "no_picture": .number(0), "idle_before_a_picture": .number(0),
            "own_time_rows": .array([]), "no_display_time": .number(0), "display_time_later": .number(0),
            "no_row": .array([]), "row_ms": .array([.number(0), .number(8.3)]),
            "lag_ms_max": .number(2), "lag_ms_mean": .number(1.5), "work_ms_max": .number(1), "work_ms_mean": .number(1),
        ])
        #expect(JSONValue(foundation: fields) == .object(["capture": .string("screencapturekit"), "lead_ms": .number(100), "screen_stream": stream]))
    }

    /// A stream that gave buffers and no row: the frames are the window list's, and the reply keeps what the stream gave.
    @Test func aStreamThatMadeNoRowKeepsItsCountsInTheWindowListsReply() {
        var tally = StreamTally()
        tally.noRow(at: 101, why: StreamTally.idleBeforeAPicture, own: false)
        tally.noRow(at: 109.3, why: StreamTally.noStatus, own: true)
        let fields = FrameStripRecording.fields(capture: .windowList, error: "ScreenCaptureKit gave no frame", stream: tally, sentAt: 100)
        let stream: JSONValue = .object([
            "buffers": .number(2), "rows": .number(0), "row_status": .string(""),
            "complete": .number(0), "idle": .number(1), "other_status": .object([:]),
            "no_status": .number(1), "no_picture": .number(0), "idle_before_a_picture": .number(1),
            "own_time_rows": .array([]), "no_display_time": .number(0), "display_time_later": .number(0),
            "no_row": .array([.array([.number(1), .number(-3), .number(0)]), .array([.number(9.3), .number(-1), .number(1)])]),
            "row_ms": .array([]),
            "lag_ms_max": .number(0), "lag_ms_mean": .number(0), "work_ms_max": .number(0), "work_ms_mean": .number(0),
        ])
        #expect(JSONValue(foundation: fields) == .object(["capture": .string("window_list"), "lead_ms": .number(100),
                                                          "capture_error": .string("ScreenCaptureKit gave no frame"), "screen_stream": stream]))
    }

    @Test func aRecordingWithNoStreamHasNoCountsInItsReply() {
        let fields = FrameStripRecording.fields(capture: .windowList, error: "own-window ScreenCaptureKit needs macOS 14.4", stream: nil, sentAt: 100.4)
        #expect(JSONValue(foundation: fields) == .object(["capture": .string("window_list"), "lead_ms": .number(100),
                                                          "capture_error": .string("own-window ScreenCaptureKit needs macOS 14.4")]))
    }
}
#endif
