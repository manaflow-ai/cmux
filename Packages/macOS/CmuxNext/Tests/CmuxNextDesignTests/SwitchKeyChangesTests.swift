@testable import CmuxNextDesign
import Testing

/// A switch timer's recording counts, per switch, how many times a cmux window became key or resigned key
/// (`debug.workspace_switch {action: "start", key_changes: true}`). A switch between two workspaces that each show
/// a Chromium page makes 2 such changes (the page that left gives the key to the cmux window in the switch's turn;
/// the page that shows takes it after its first frame), and Chromium makes none on a tab switch. The second change
/// comes after the switch's own commit, so a switch owns the marks up to the next switch's intent.
@MainActor @Suite struct SwitchKeyChangesTests {
    typealias Mark = SwitchKeyChanges.Mark

    @Test func eachSwitchOwnsTheMarksUpToTheNextSwitchsIntent() {
        // Three switches, 400 ms apart. Each: the cmux window becomes key 20 ms after the intent and resigns 60 ms
        // after it. The third also has a late change, long after its commit.
        let marks = [100.0, 500, 900].flatMap { [Mark(became: true, at: $0 + 20), Mark(became: false, at: $0 + 60)] }
            + [Mark(became: true, at: 2_400)]
        let columns = SwitchKeyChanges(marks: marks).columns(forRowsAt: [100, 500, 900])
        #expect(columns == [
            ["key_changes": 2, "key_become": 1, "key_resign": 1, "key_marks_full": 0],
            ["key_changes": 2, "key_become": 1, "key_resign": 1, "key_marks_full": 0],
            ["key_changes": 3, "key_become": 2, "key_resign": 1, "key_marks_full": 0],
        ])
    }

    @Test func aSwitchWithNoKeyChangeCountsZeroAndAMarkBeforeTheFirstSwitchIsNoSwitchs() {
        // The recording started, the cmux window became key (the app came to the front), then two terminal switches.
        let columns = SwitchKeyChanges(marks: [Mark(became: true, at: 40)]).columns(forRowsAt: [300, 700])
        #expect(columns.map { $0["key_changes"] } == [0, 0])
        #expect(columns.map { $0["key_become"] } == [0, 0] && columns.map { $0["key_resign"] } == [0, 0])
    }

    @Test func aMarkAtASwitchsIntentIsThatSwitchsNotTheOneBefore() {
        let columns = SwitchKeyChanges(marks: [Mark(became: false, at: 500)]).columns(forRowsAt: [100, 500])
        #expect(columns.map { $0["key_changes"] } == [0, 1])
    }

    @Test func rowsOutOfTimeOrderStillOwnTheirOwnMarks() {
        // The rows come in the order their frames showed; a later intent can show first.
        let changes = SwitchKeyChanges(marks: [Mark(became: true, at: 150), Mark(became: true, at: 520), Mark(became: false, at: 560)])
        #expect(changes.columns(forRowsAt: [500, 100]).map { $0["key_changes"] } == [2, 1])
    }

    @Test func aRowWithNoPlaceGetsNoColumnAndTakesNoMark() {
        let changes = SwitchKeyChanges(marks: [Mark(became: true, at: 300), Mark(became: true, at: 600)])
        let columns = changes.columns(forRowsAt: [100, nil, 500])
        #expect(columns.map { $0["key_changes"] } == [1, nil, 1])
        #expect(columns[1].isEmpty)
    }

    @Test func theMarksAreTheKeySpansOfTheRecordingAndAFullRingIsSaid() {
        let spans: [(name: String, start: Double)] = [("show.park", 101), ("key.become", 120), ("commit", 130), ("key.resign", 180), ("key.becomeMain", 190)]
        let changes = SwitchKeyChanges(spans: spans, capacity: 512)
        #expect(changes == SwitchKeyChanges(marks: [Mark(became: true, at: 120), Mark(became: false, at: 180)], full: false))
        #expect(SwitchKeyChanges(spans: spans, capacity: 5).full, "the spans filled their ring: later marks are missing")
        #expect(SwitchKeyChanges(spans: spans, capacity: 5).columns(forRowsAt: [100]) == [["key_changes": 2, "key_become": 1, "key_resign": 1, "key_marks_full": 1]])
    }

    @Test func eachPlacedRowGetsItsCountsAndKeepsItsOwnColumns() {
        let rows: [[String: Double]] = [
            ["at_ms": 100, "commit_ms": 17.5],
            ["at_ms": 500, "commit_ms": 11.25, "key_changes": 7],
            ["commit_ms": 9],
        ]
        let marks = [Mark(became: true, at: 120), Mark(became: false, at: 180), Mark(became: true, at: 520)]
        let counted = SwitchKeyChanges(marks: marks).counted(rows)
        #expect(counted.count == 3)
        #expect(counted[0] == ["at_ms": 100, "commit_ms": 17.5, "key_changes": 2, "key_become": 1, "key_resign": 1, "key_marks_full": 0])
        #expect(counted[1]["key_changes"] == 7, "a row's own column of the same name stays")
        #expect(counted[1]["key_become"] == 1 && counted[1]["key_resign"] == 0)
        #expect(counted[2] == ["commit_ms": 9], "a row with no at_ms gets no count")
        #expect(SwitchKeyChanges(marks: marks).counted([]).isEmpty)
    }
}
