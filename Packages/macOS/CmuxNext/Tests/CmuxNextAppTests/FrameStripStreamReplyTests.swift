#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextDesign
import CmuxNextSettings
import Testing

/// The frame strip's reply with the recorder's counts of its stream (`screen_stream`, ``StreamTally``). The app puts a
/// recording's fields into the reply only when ALL of them convert to the reply's values (`JSONValue(foundation:)`
/// in `DebugFrameStrip`): one value that does not convert would take `capture` out of the reply too, and the reader
/// of the frames then judges no recording. No stream runs here: the tally gets its buffers by hand, with a value in
/// each field of the reply.
struct FrameStripStreamReplyTests {
    @Test func aTallyWithAValueInEachFieldGoesThroughTheReplysConversion() {
        var tally = StreamTally()
        // 7 buffers, the key at 100 ms: 2 with no row before the first picture, 3 rows, 2 with no row after them.
        tally.noRow(at: 90, why: StreamTally.noStatus)
        tally.noRow(at: 95, why: StreamTally.idleBeforeAPicture)
        tally.row("c", index: 0, at: 100.04, time: .display(age: 3.26), work: 1.24)
        tally.row("i", index: 1, at: 108.4, time: .missing, work: 0)
        tally.row("c", index: 2, at: 116.7, time: .later, work: 2)
        tally.noRow(at: 118, why: StreamTally.noPicture)
        tally.noRow(at: 120, why: 2)
        let fields = FrameStripRecording.fields(capture: .screenCaptureKit, error: nil, stream: tally, sentAt: 100)
        let stream: JSONValue = .object([
            "buffers": .number(7), "rows": .number(3), "row_status": .string("cic"),
            "complete": .number(3), "idle": .number(2), "other_status": .object(["2": .number(1)]),
            "no_status": .number(1), "no_picture": .number(1), "idle_before_a_picture": .number(1),
            "own_time_rows": .array([.number(1), .number(2)]), "no_display_time": .number(1), "display_time_later": .number(1),
            "no_row": .array([.array([.number(-10), .number(-1)]), .array([.number(-5), .number(-3)]),
                              .array([.number(18), .number(-2)]), .array([.number(20), .number(2)])]),
            "row_ms": .array([.number(0), .number(8.4), .number(16.7)]),
            "lag_ms_max": .number(3.3), "lag_ms_mean": .number(3.3), "work_ms_max": .number(2), "work_ms_mean": .number(1.6),
        ])
        #expect(JSONValue(foundation: fields) == .object(["capture": .string("screencapturekit"), "lead_ms": .number(100), "screen_stream": stream]),
                "nil: one value of the recording's fields does not convert, and the reply then has no `capture`")
    }

    @Test func aRecordingWithNoStreamHasNoCountsInItsReply() {
        let fields = FrameStripRecording.fields(capture: .windowList, error: "ScreenCaptureKit gave no frame", stream: nil, sentAt: 100.4)
        #expect(JSONValue(foundation: fields) == .object(["capture": .string("window_list"), "lead_ms": .number(100),
                                                          "capture_error": .string("ScreenCaptureKit gave no frame")]))
    }
}
#endif
