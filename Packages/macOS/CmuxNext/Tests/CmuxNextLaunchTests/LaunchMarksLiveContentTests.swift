import CmuxNextLaunch
import Foundation
import Testing

/// `first_live_content_frame` is the first live content frame of any kind, once, and a paint
/// no one sees is no live content.
struct LaunchMarksLiveContentTests {
    private let processStart = Date(timeIntervalSince1970: 1_000)

    /// Records `name` at `ms` the way `DebugTimings.markLaunch` does: a first record also records its derived mark.
    private func record(_ name: String, ms: Double, in marks: inout LaunchMarks) {
        let date = processStart.addingTimeInterval(ms / 1_000)
        guard marks.record(name, at: date, processStart: processStart) != nil else { return }
        if let derived = LaunchMarks.derivedMark(of: name) { record(derived, ms: ms, in: &marks) }
    }

    private func times(of name: String, in marks: LaunchMarks) -> [Double] {
        marks.all.filter { $0.name == name }.map { ($0.ms * 10).rounded() / 10 }
    }

    @Test func aNameIsRecordedOnce() {
        var marks = LaunchMarks()
        record("run_loop_start", ms: 40, in: &marks)
        record("run_loop_start", ms: 90, in: &marks)
        #expect(times(of: "run_loop_start", in: marks) == [40])
        #expect(marks.contains("run_loop_start"))
        #expect(!marks.contains("first_idle"))
    }

    @Test func theFirstLiveContentFrameOfAnyKindIsFirstLiveContentFrame() {
        var marks = LaunchMarks()
        record("first_page_frame", ms: 250, in: &marks)
        record("first_terminal_frame", ms: 300, in: &marks)
        #expect(times(of: "first_live_content_frame", in: marks) == [250])
        #expect(marks.all.map(\.name) == ["first_page_frame", "first_live_content_frame", "first_terminal_frame"])
    }

    @Test func aPaintNoOneSeesIsNoLiveContent() {
        var marks = LaunchMarks()
        // The agent page marks every page's paint, the New Tab spare's out of sight included.
        record("agent_pane.newtab_painted", ms: 120, in: &marks)
        record("agent_pane.painted", ms: 130, in: &marks)
        #expect(!marks.contains("first_live_content_frame"))
        record("first_terminal_frame", ms: 280, in: &marks)
        #expect(times(of: "first_live_content_frame", in: marks) == [280])
    }
}
