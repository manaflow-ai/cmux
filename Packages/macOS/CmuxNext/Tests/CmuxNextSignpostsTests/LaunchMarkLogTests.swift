import CmuxNextSignposts
import Testing

/// p08-startup-002: each launch milestone lands once, `first_live_content_frame` is the first
/// live content frame of any kind, and `startup_complete` names its first reason only.
struct LaunchMarkLogTests {
    @Test func aNameIsRecordedOnceAtItsFirstTime() {
        var log = LaunchMarkLog()
        #expect(log.record("run_loop_start", ms: 40) == [.init(name: "run_loop_start", ms: 40)])
        #expect(log.record("run_loop_start", ms: 90).isEmpty)
        #expect(log.marks == [.init(name: "run_loop_start", ms: 40)])
        #expect(log.contains("run_loop_start"))
        #expect(!log.contains("first_idle"))
    }

    @Test func theFirstLiveContentFrameOfAnyKindIsFirstLiveContentFrame() {
        var log = LaunchMarkLog()
        #expect(log.record("first_page_frame", ms: 250) == [
            .init(name: "first_page_frame", ms: 250), .init(name: "first_live_content_frame", ms: 250),
        ])
        #expect(log.record("first_terminal_frame", ms: 300) == [.init(name: "first_terminal_frame", ms: 300)])
        #expect(log.marks.filter { $0.name == "first_live_content_frame" } == [.init(name: "first_live_content_frame", ms: 250)])
    }

    @Test func aPaintNoOneSeesIsNoLiveContent() {
        var log = LaunchMarkLog()
        // The agent page marks every page's paint, the New Tab spare's out of sight included.
        _ = log.record("agent_pane.newtab_painted", ms: 120)
        _ = log.record("agent_pane.painted", ms: 130)
        #expect(!log.marks.contains { $0.name == "first_live_content_frame" })
        _ = log.record("first_terminal_frame", ms: 280)
        #expect(log.marks.last == .init(name: "first_live_content_frame", ms: 280))
    }

    @Test func startupCompleteNamesItsFirstReasonOnly() {
        var log = LaunchMarkLog()
        #expect(log.recordStartupComplete(.visiblePaneLoadedIdle, ms: 800) == [
            .init(name: "startup_complete", ms: 800), .init(name: "startup_complete.visiblePaneLoadedIdle", ms: 800),
        ])
        #expect(log.recordStartupComplete(.failsafe, ms: 10_000).isEmpty)
        #expect(!log.marks.contains { $0.name == "startup_complete.failsafe" })
        #expect(log.marks.count == 2)
    }

    @Test func eachReasonNamesItsOwnMark() {
        let names = StartupCompleteReason.allCases.map { reason in
            var log = LaunchMarkLog()
            return log.recordStartupComplete(reason, ms: 1).last?.name
        }
        #expect(names == ["startup_complete.visiblePaneLoadedIdle", "startup_complete.visiblePaneTimedOut",
                          "startup_complete.noVisiblePane", "startup_complete.noWindow",
                          "startup_complete.daemonUnavailable", "startup_complete.failsafe"])
    }
}
