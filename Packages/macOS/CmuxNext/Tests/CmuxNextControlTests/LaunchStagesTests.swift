import CmuxNextControl
import Foundation
import Testing

/// Each launch's row of launch-times.jsonl names its startup stages (startup-tti), each ms from process start, with
/// whether it was cold or warm and how many workspaces it restored. Leo, 2026-11-21: "you can build instrumentation
/// if you havent already to properly measure each part of startup times."
@Suite struct LaunchStagesTests {
    static let marks: [String: Double] = [
        "main_start": 41.25, "did_finish_launching_start": 120.5, "daemon_connected": 180,
        "dfl.windows": 300, "launch_snapshot_shown": 260.04, "first_window_frame_committed": 512.04,
        "cef.ready": 700, "home.first_page": 830.66, "agent_pane.painted": 790, "window_usable": 900,
        "terminal_echo": 640, "reveal.home": 830.7, "browser_pane.first_paint": 760,
    ]

    @Test func everyStageIsTheEarliestOfItsMarks() {
        let spans = LaunchStages.spans(Self.marks)
        #expect(spans == [
            "premain": 41.25, "did_finish_launching": 120.5, "daemon_connected": 180,
            "first_window_shown": 260.04, "first_frame": 512.04, "webview_ready": 700,
            "first_chat_paint": 790, "first_browser_paint": 760, "first_interaction": 640,
        ])
    }

    @Test func aStageNoMarkReachedIsAbsentAndBadMarksAreSkipped() {
        let spans = LaunchStages.spans(["main_start": 40, "cef.ready": -1, "window_usable": .nan])
        #expect(spans == ["premain": 40])
        #expect(LaunchStages.spans([:]).isEmpty)
    }

    @Test func theTableIsInLaunchOrderAndNamesEachStageOnce() {
        let stages = LaunchStages.table.map(\.stage)
        #expect(stages == ["dyld", "premain", "main_setup", "did_finish_launching", "daemon_connected", "first_window_shown",
                           "first_frame", "webview_ready", "first_page_navigation", "first_page_dom_content_loaded",
                           "first_page_contentful_paint", "first_chat_paint", "first_browser_paint", "first_interaction"])
        #expect(Set(stages).count == stages.count)
    }

    @Test func theRowCarriesStagesKindAndWorkspaces() throws {
        let file = LaunchTimesFileTests.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let record = LaunchTimesRecord(marks: Self.marks, startedAt: Date(timeIntervalSince1970: 1_800_000_000), version: "1.0.0",
                                       build: "200", commit: "31583607", prewarmed: false, workspaces: 12)
        #expect(record.stages?["first_window_shown"] == 260)
        #expect(record.stages?["premain"] == 41.3)
        let line = try file.append(record)
        #expect(line.contains(#""launch_kind":"cold""#), "the first launch of a build, not pre-warmed")
        #expect(line.contains(#""workspaces":12"#))
        #expect(line.contains(#""stages":{"#))
        // The next launch of the same build is warm; a pre-warmed first launch is warm too.
        try file.append(LaunchTimesRecord(marks: Self.marks, startedAt: Date(timeIntervalSince1970: 1_800_000_100), version: "1.0.0",
                                          build: "200", commit: "31583607", prewarmed: false))
        try file.append(LaunchTimesRecord(marks: Self.marks, startedAt: Date(timeIntervalSince1970: 1_800_000_200), version: "1.0.0",
                                          build: "201", commit: "aa", prewarmed: true))
        #expect(file.records().map(\.launchKind) == ["cold", "warm", "warm"])
    }

    /// The pre-main split, main's own setup and the first page's timeline are stages of their own.
    @Test func thePremainSplitSetupAndFirstPageAreStages() {
        let spans = LaunchStages.spans(["premain.first_initializer": 31.5, "main_start": 41.25, "main.setup_done": 47,
                                        "first_page.navigation_start": 720, "first_page.dom_content_loaded": 760,
                                        "first_page.first_contentful_paint": 781])
        #expect(spans == ["dyld": 31.5, "premain": 41.25, "main_setup": 47, "first_page_navigation": 720,
                          "first_page_dom_content_loaded": 760, "first_page_contentful_paint": 781])
    }

    /// The row says whether the launch spawned its daemon or reused one: the earlier of the two marks.
    @Test func theRowSaysWhetherTheDaemonWasSpawned() throws {
        func row(_ marks: [String: Double]) -> LaunchTimesRecord {
            LaunchTimesRecord(marks: marks, startedAt: Date(timeIntervalSince1970: 1_800_000_000), version: "1.0.0", build: "200",
                              commit: "c", prewarmed: false)
        }
        #expect(row(["daemon.spawned": 300]).daemonSpawned == true)
        #expect(row(["daemon.reused": 90]).daemonSpawned == false)
        #expect(row(["daemon.reused": 90, "daemon.spawned": 4_000]).daemonSpawned == false, "a later reconnect's spawn is not the launch's")
        #expect(row([:]).daemonSpawned == nil)
        let file = LaunchTimesFileTests.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let line = try file.append(row(["daemon.spawned": 300]))
        #expect(line.contains(#""daemon_spawned":true"#))
        #expect(file.records().first?.phases?["daemon.spawned"] == 300)
    }

    /// The first page's answer becomes its marks on the wall clock; entries it lacks are left out.
    @Test func theFirstPageAnswerBecomesMarks() {
        let marks = LaunchFirstPage.marks("1800000000000.5,40.25,61")
        #expect(marks.map(\.name) == [LaunchFirstPage.navigationStart, LaunchFirstPage.domContentLoaded, LaunchFirstPage.firstContentfulPaint])
        #expect(abs(marks[0].at.timeIntervalSince1970 - 1_800_000_000.0005) < 1e-6)
        #expect(abs(marks[2].at.timeIntervalSince1970 - 1_800_000_000.0615) < 1e-6)
        #expect(LaunchFirstPage.marks("1800000000000,0,-1").map(\.name) == [LaunchFirstPage.navigationStart])
        #expect(LaunchFirstPage.marks("").isEmpty && LaunchFirstPage.marks("x,1,2").isEmpty && LaunchFirstPage.marks("0,1,2").isEmpty)
    }

    /// The prior chat's rewrite of the row (no workspace count of its own) keeps the count the first write had.
    @Test func theRewriteKeepsTheWorkspaceCount() throws {
        let file = LaunchTimesFileTests.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try file.append(LaunchTimesRecord(marks: Self.marks, startedAt: start, version: "1.0.0", build: "200", commit: "c",
                                          prewarmed: false, workspaces: 3))
        try file.append(LaunchTimesRecord(marks: Self.marks, startedAt: start, version: "1.0.0", build: "200", commit: "c",
                                          prewarmed: false), rewritingLast: true)
        #expect(file.records().count == 1)
        #expect(file.records().first?.workspaces == 3)
    }

    /// A row an older build wrote (no stages) still reads back.
    @Test func aRowFromBeforeTheStagesReadsBack() throws {
        let file = LaunchTimesFileTests.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = #"{"build":"200","first_launch_of_build":true,"prewarmed":false,"started_at":"2027-01-15T08:00:00Z","version":"1.0.0"}"#
        try Data((old + "\n").utf8).write(to: file.url)
        let row = try #require(file.records().first)
        #expect(row.stages == nil && row.launchKind == nil && row.workspaces == nil)
    }
}
