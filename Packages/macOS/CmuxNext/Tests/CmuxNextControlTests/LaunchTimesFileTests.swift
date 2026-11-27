import CmuxNextCompat
import CmuxNextControl
import CmuxNextWakeups
import Foundation
import Testing

/// Each launch of every build (release and NIGHTLY too) leaves one record of its launch marks in a file of the last
/// 50 launches, which `cmux app launch-times` reads (CMUX-571): the marks themselves live only in memory and
/// `debug.timings` answers only in a debug build.
@Suite struct LaunchTimesFileTests {
    static let marks: [String: Double] = [
        "main_start": 41.25, "first_window_frame_committed": 512.04, "home.first_page": 830.66,
        "reveal.home": 830.7, "dfl.menu": 200,
    ]

    static func temporaryFile(capacity: Int = LaunchTimesFile.capacity) -> LaunchTimesFile {
        LaunchTimesFile(url: FileManager.default.temporaryDirectory
            .appending(path: "launch-times-\(UUID().uuidString)/launch-times.jsonl"), capacity: capacity)
    }

    static func record(build: String = "200", marks: [String: Double] = marks, prewarmed: Bool = false,
                       prewarmReason: String? = nil) -> LaunchTimesRecord {
        LaunchTimesRecord(marks: marks, startedAt: Date(timeIntervalSince1970: 1_800_000_000), version: "1.0.0",
                          build: build, commit: "31583607", prewarmed: prewarmed, prewarmReason: prewarmReason)
    }

    @Test func aRecordCarriesTheLaunchesTimes() {
        let record = Self.record(prewarmed: true)
        #expect(record.preMainMs == 41.3)
        #expect(record.firstWindowFrameMs == 512)
        #expect(record.mainMs == 470.8, "main to the first frame")
        #expect(record.homeFirstPageMs == 830.7)
        #expect(record.homeRevealedBy == "mark")
        #expect(record.prewarmed)
        #expect(record.version == "1.0.0" && record.build == "200" && record.commit == "31583607")
        #expect(record.startedAt == "2027-01-15T08:00:00Z")
        var deadline = Self.marks
        deadline["reveal.home.by_deadline"] = 1700
        deadline["home.first_page"] = nil
        let byDeadline = Self.record(marks: deadline)
        #expect(byDeadline.homeRevealedBy == "deadline")
        #expect(byDeadline.homeFirstPageMs == nil)
        #expect(record.windowUsableMs == nil && record.firstShellLiveMs == nil && record.noSnapshot == false)
    }

    /// A launch with nothing to restore (piece 8, the bare launch) records when its window took keys and its first shell went live.
    @Test func aBareLaunchRecordsWhenItsWindowTookKeysAndItsShellWentLive() throws {
        var marks = Self.marks
        marks["launch.no_snapshot"] = 60
        marks["window_usable"] = 231.04
        marks["first_shell_live"] = 512.96
        let record = Self.record(marks: marks)
        #expect(record.noSnapshot == true)
        #expect(record.windowUsableMs == 231)
        #expect(record.firstShellLiveMs == 513)
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let line = try file.append(record)
        #expect(line.contains(#""window_usable_ms":231"#) && line.contains(#""first_shell_live_ms":513"#) && line.contains(#""no_snapshot":true"#))
    }

    /// A line an older build wrote (no bare-launch fields) still reads back.
    @Test func aRecordFromBeforeTheBareLaunchFieldsReadsBack() throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = #"{"build":"200","first_launch_of_build":true,"prewarmed":false,"started_at":"2027-01-15T08:00:00Z","version":"1.0.0"}"#
        try Data((old + "\n").utf8).write(to: file.url)
        let records = file.records()
        #expect(records.count == 1)
        #expect(records.first?.noSnapshot == nil && records.first?.windowUsableMs == nil)
    }

    /// Home shows from its saved state before the Chief's first page (launch piece 3): the record is
    /// written at `reveal.home`, so its Home time is the saved page's, not a nil for a page still to come.
    @Test func homesTimeIsItsSavedPageWhenItShowedFirst() {
        var marks = Self.marks
        marks["home.first_page"] = nil
        marks["home.saved_page_shown"] = 640.04
        marks["reveal.home"] = 640.1
        let record = Self.record(marks: marks)
        #expect(record.homeFirstPageMs == 640)
        #expect(record.homeRevealedBy == "mark")
    }

    @Test func aLaunchWritesOneLineThatReadsBack() throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let line = try file.append(Self.record(prewarmed: true, prewarmReason: "main"))
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text == line + "\n", "one line per launch")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(Set(json.keys) == ["started_at", "version", "build", "commit", "pre_main_ms", "main_ms", "first_window_frame_ms",
                                   "home_first_page_ms", "home_revealed_by", "no_snapshot", "prewarmed", "prewarm_reason", "first_launch_of_build", "phases", "stages", "launch_kind"])
        #expect(json["prewarm_reason"] as? String == "main")
        var expected = Self.record(prewarmed: true, prewarmReason: "main")
        expected.firstLaunchOfBuild = true
        expected.launchKind = "warm" // append() derives it: a prewarmed launch is warm
        #expect(file.records() == [expected])
    }

    @Test func onlyAnotherBuildsLaunchBeforeMakesTheFirstLaunchOfABuild() throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try file.append(Self.record(build: "199"))
        try file.append(Self.record(build: "200"))
        try file.append(Self.record(build: "200"))
        #expect(file.records().map(\.firstLaunchOfBuild) == [true, true, false])
    }

    @Test func theFileKeepsOnlyTheLastLaunches() throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        for build in 1...(LaunchTimesFile.capacity + 12) { try file.append(Self.record(build: "\(build)")) }
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == LaunchTimesFile.capacity)
        #expect(file.records().map(\.build) == ((13...(LaunchTimesFile.capacity + 12)).map { "\($0)" }), "the newest, oldest first")
    }

    /// A file that is not one this wrote (too large to be 50 records) is started over, never read whole.
    @Test func anOversizedFileIsStartedOver() throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "x"), count: 300 * 1024).write(to: file.url)
        try file.append(Self.record())
        #expect(file.records().count == 1)
    }

    /// A relaunch into the workspace whose agent chat was in front at the quit (CMUX-119), with the marks the
    /// quit-reopen harness reads (scripts/ci/quit_gamut_check.py).
    static let chatMarks: [String: Double] = [
        LaunchPriorChat.frontMark: 700.02, "agent_pane.painted": 1234.47, "agent_pane.transport_open": 1490.18,
    ]

    static func merged(_ extra: [String: Double]) -> [String: Double] { marks.merging(extra) { _, new in new } }

    /// The restored front tab is a chat and its marks are in: the row has both columns, on the process-start clock.
    @Test func aChatInFrontFillsThePriorChatsColumns() throws {
        let record = Self.record(marks: Self.merged(Self.chatMarks))
        #expect(record.priorChatPaintedMs == 1234.5, "in front and drawn")
        #expect(record.priorChatLiveMs == 1490.2, "and its stream open")
        // Live is never before drawn: a stream open first counts from the drawing.
        let early = Self.record(marks: Self.merged(Self.chatMarks.merging(["agent_pane.transport_open": 900]) { _, new in new }))
        #expect(early.priorChatLiveMs == 1234.5)
        let line = try Self.temporaryFile().encodedLine(record)
        #expect(line.contains(#""prior_chat_painted_ms":1234.5"#) && line.contains(#""prior_chat_live_ms":1490.2"#), "\(line)")
    }

    /// Another tab in front (a terminal; the chat painted in another pane), or a chat not drawn yet: no columns.
    @Test func noChatInFrontLeavesThePriorChatsColumnsOut() throws {
        var notFront = Self.chatMarks
        notFront[LaunchPriorChat.frontMark] = nil
        var notLive = Self.chatMarks
        notLive["agent_pane.transport_open"] = nil
        for marks in [Self.marks, Self.merged(notFront), Self.merged(notLive)] {
            let record = Self.record(marks: marks)
            #expect(record.priorChatPaintedMs == nil && record.priorChatLiveMs == nil, "\(marks.keys.sorted())")
            let line = try Self.temporaryFile().encodedLine(record)
            #expect(!line.contains("prior_chat"), "\(line)")
        }
    }

    /// The watch hands out the prior chat's marks once: on the mark that completes them, never before, never again.
    @Test func thePriorChatsMarksCompleteOnce() {
        let watch = LaunchPriorChatWatch()
        var marks = Self.marks
        var completed: [String] = []
        for (name, ms) in [("dfl.menu", 10.0), (LaunchPriorChat.frontMark, 700), ("agent_pane.painted", 1234), ("reveal.pane", 1240),
                           ("agent_pane.transport_open", 1490), ("agent_pane.painted", 1500), ("agent_pane.transport_open", 1600)] {
            marks[name] = ms
            if watch.complete(after: name, marks: { marks }) != nil { completed.append(name) }
        }
        #expect(completed == ["agent_pane.transport_open"])
    }

    @Test func aChatAlreadyLiveAtTheFirstFrameIsRecorded() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let marks = Self.merged(Self.chatMarks)
        _ = LaunchTimesRecorder(file: file, work: BackgroundWork(label: "test.already-live"), info: [:],
                                marks: { marks }, prewarmed: { _ in (preWarmed: false, reason: "no_record") })
        _ = try await Self.lines(file, until: { !$0.isEmpty })
        let rows = file.records()
        #expect(rows.count == 1)
        #expect(rows.first?.priorChatPaintedMs == 1234.5 && rows.first?.priorChatLiveMs == 1490.2)
    }

    /// The launch's row is written at the first frame, then rewritten exactly once with the prior chat's columns
    /// when its marks arrive: still one line, pre-warmed as first read (its marker is consumed on reading).
    @Test func theRowIsRewrittenOnceWhenThePriorChatsMarksArrive() async throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try file.append(Self.record(build: "199"))
        let asked = Asked()
        let work = BackgroundWork(label: "test.launch-times")
        let recorder = LaunchTimesRecorder(file: file, work: work,
                                           info: ["CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "200"]) { _ in
            asked.count.withLock { count in count += 1; return (preWarmed: count == 1, reason: count == 1 ? "full" : "no_record") }
        }
        recorder.write(marks: Self.marks)
        let first = try await Self.lines(file, until: { $0.count == 2 })
        #expect(first.last?.contains("prior_chat") == false, "no chat marks yet: \(first)")
        var marks = Self.marks
        for (name, ms) in Self.chatMarks.sorted(by: { $0.value < $1.value }) + [("agent_pane.painted", 1600)] {
            marks[name] = ms
            recorder.heard(name, marks: { marks })
        }
        let rewritten = try await Self.lines(file, until: { $0.last?.contains("prior_chat_live_ms") == true })
        #expect(rewritten.count == 2, "rewritten, not appended: \(rewritten)")
        let records = file.records()
        #expect(records.map(\.build) == ["199", "200"])
        #expect(records.last?.priorChatPaintedMs == 1234.5 && records.last?.priorChatLiveMs == 1490.2)
        #expect(records.last?.prewarmed == true && records.last?.prewarmReason == "full", "the rewrite keeps the first read's answer")
        #expect(records.last?.preMainMs == 41.3, "and every other column")
        // A late first write (the Home gate after the chat) keeps the chat's columns and is no third line.
        recorder.write(marks: Self.marks)
        // The files lane runs its best-effort items one at a time, in order: once this one ran, the late write has.
        await withCheckedContinuation { (ran: CheckedContinuation<Void, Never>) in
            work.post(.bestEffort, mayBlock: .files) { ran.resume() }
        }
        #expect(file.records().count == 2 && file.records().last?.priorChatLiveMs == 1490.2)
        #expect(asked.count.withLock { $0 } == 1, "pre-warm asked once")
    }

    static func lines(_ file: LaunchTimesFile, until done: ([String]) -> Bool) async throws -> [String] {
        for _ in 0..<200 {
            let lines = ((try? String(contentsOf: file.url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            if done(lines) { return lines }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("the file never got there")
        return []
    }

    /// Each phase mark the launch reached is in its row under `phases`, rounded like the other columns; a mark
    /// not in ``LaunchTimesRecord/phaseMarks`` stays out, and a launch that reached none has no `phases`.
    @Test func aRowCarriesTheLaunchesPhases() throws {
        let phases: [String: Double] = [
            "did_finish_launching_start": 60.04, "dfl.settings_read": 70.1, "dfl.services": 90.26, "dfl.app_actions": 110, "dfl.bind": 120,
            "dfl.menu": 130.55, "daemon.prepare_start": 140, "daemon.prepare_end": 300.04, "daemon.socket_connected": 310,
            "daemon_connected": 320, "launch_snapshot_applied": 330, "launch_snapshot_shown": 340, "dfl.windows": 350,
            "did_finish_launching_end": 360, "cef.initialize_start": 400, "cef.ready": 900, "reveal.sidebar": 700,
            "main.warmup_started": 42, "main.environment": 43, "main.state_folder": 44, "main.reads_started": 45,
            "main.crash_handlers": 46, "main.nsapp_made": 47.5, "main.launch_shell_made": 47.6, "main.delegate.fields": 47.7, "main.control.fields": 47.8,
            "main.delegate.first_frame_gate": 47.9, "main.delegate.main_work": 48, "main.delegate.control": 48.1, "main.delegate_made": 48.25, "main.nsapp": 50, "main.run": 55, "app.did_finish_launching_entry": 56,
            "app.launch_snapshot_awaited": 57, "cloud_env.start": 58, "cloud_env.cli_exited": 59, "cloud_env.awaited": 59.5,
            "dfl.theme": 75, "dfl.settings": 125, "daemon.binary_resolved": 150, "dfl.daemon_cloud_updater": 325,
            "dfl.first_window_hooks": 335, "dfl.home_history": 345, "daemon_snapshot_loaded": 365,
            "connecting_view_shown": 366, "connecting_view_left": 367, "workspace_content_shown": 368,
            "sidebar_rows_shown": 369, "first_window_flushed": 370, "pages.deferred_until_frame": 370.5, "agent_pane.launch_image_shown": 371,
            "first_terminal_surface_created": 380, "first_terminal_content": 450, "first_terminal_content_applied": 451,
            "first_terminal_frame": 452, "chromium_page.make_start": 410, "chromium_page.browser_created": 420,
            "home.page_host_made": 430, "pages.created": 460, "agent_pane.view_created": 600, "agent_pane.transport_open": 650,
            "browser_pane.first_paint": 700.04, "browser_pane.input_ready": 720,
            "terminal_input_accepted": 640, "terminal_echo": 645,
            "window.make_start": 341, "window.sidebar_made": 341.25, "window.root_made": 341.5, "window.shell_made": 341.75,
            "window.content_installed": 342, "window.backdrop_applied": 342.5, "window.init_done": 343, "window.configured": 344, "window.workspace_shown": 345, "window.ordered_front": 346, "window.restore_wait_start": 361,
            "window.restore_wait_end": 362.25, "frame.commit_start": 363, "window.display_done": 400, "window.flush_done": 401, "frame.loop_1": 402, "frame.loop_2": 403, "frame.loop_3": 404, "frame.loop_4": 405, "first_key_down": 630,
            "premain.first_initializer": 31, "main.setup_done": 41.5, "daemon.spawned": 290, "daemon.reused": 299,
            "first_page.navigation_start": 905, "first_page.dom_content_loaded": 940, "first_page.first_contentful_paint": 962,
        ]
        let record = Self.record(marks: Self.merged(phases))
        var expected = phases.mapValues { ($0 * 10).rounded() / 10 }
        expected["reveal.home"] = 830.7
        #expect(record.phases == expected)
        #expect(Set(LaunchTimesRecord.phaseMarks) == Set(expected.keys), "every phase mark is covered")
        let line = try Self.temporaryFile().encodedLine(record)
        #expect(line.contains(#""phases":{"#) && line.contains(#""dfl.services":90.3"#), "\(line)")
        #expect(!line.contains(#""home.first_page""#), "only phase marks go under phases: \(line)")
        #expect(Self.record(marks: ["main_start": 41]).phases == nil)
        #expect(try !Self.temporaryFile().encodedLine(Self.record(marks: ["main_start": 41])).contains("phases"))
    }

    /// The row keeps the slowest ``LaunchTimesRecord/binderCount`` binders of the launch's `AppActions.bind`, rounded to
    /// hundredths, and none without any (startup-under-100ms).
    @Test func aRowKeepsTheSlowestBinders() throws {
        let binders = Dictionary(uniqueKeysWithValues: (0..<40).map { ("Binder\($0).bind", Double($0) / 3) })
        let record = LaunchTimesRecord(marks: ["main_start": 41], startedAt: Date(timeIntervalSince1970: 1_800_000_000), version: "1.0.0",
                                       build: "200", commit: nil, prewarmed: false, binders: binders)
        #expect(record.binders?.count == LaunchTimesRecord.binderCount)
        #expect(record.binders?["Binder39.bind"] == 13)
        #expect(record.binders?["Binder24.bind"] == 8)
        #expect(record.binders?["Binder23.bind"] == nil)
        #expect(try Self.temporaryFile().encodedLine(record).contains(#""binders":{"#))
        #expect(Self.record(marks: ["main_start": 41]).binders == nil)
    }

    /// A row written before `phases` existed still reads back, with none.
    @Test func aRowWithoutPhasesStillDecodes() throws {
        let line = #"{"build":"200","commit":"31583607","first_launch_of_build":true,"first_window_frame_ms":512,"main_ms":470.8,"pre_main_ms":41.3,"prewarmed":false,"started_at":"2027-01-15T08:00:00Z","version":"1.0.0"}"#
        let record = try JSONDecoder().decode(LaunchTimesRecord.self, from: Data(line.utf8))
        #expect(record.phases == nil && record.mainMs == 470.8)
    }

    @Test func noTestProcessWritesThePersonsFile() {
        #expect(LaunchTimesFile.app(bundleID: "com.cmuxterm.app.nightly") == nil)
    }
}

/// How many times the recorder asked whether the build was pre-warmed.
private final class Asked: Sendable {
    let count = Mutex(0)
}

private extension LaunchTimesFile {
    /// The line `record` is written as, in a file of its own.
    func encodedLine(_ record: LaunchTimesRecord) throws -> String {
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try append(record)
    }
}
