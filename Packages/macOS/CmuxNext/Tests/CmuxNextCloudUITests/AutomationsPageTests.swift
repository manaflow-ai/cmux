import AppKit
import CmuxNextCloudUI
import CmuxNextDesign
import Foundation
import SwiftUI
import Testing

/// The Automations page (docs/automations-platonic-ideal.md section 8, option A): both sources in one
/// list, failures first under "Needs you", paused last, a source that fails keeps the other's rows,
/// and the sidebar badge counts failures only. The last test renders the page light and dark to PNG
/// for review (written to `$CMUX_AUTOMATIONS_SHOTS`, else the repository's `.build/artifacts/automations-page.png`).
@MainActor @Suite(.serialized) struct AutomationsPageTests {
    /// Friday 2026-10-30 08:00 local.
    nonisolated static let now: Date = {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, 30, 8, 0)
        return Calendar.current.date(from: c)!
    }()

    nonisolated static let localJSON = Data("""
    {"automations": [
      {"id": "auto_aaaaaaaaaaaaaaaaaaaa", "name": "Unblock agents", "enabled": true, "trigger": {"type": "every", "seconds": 1800},
       "body": {"type": "prompt", "prompt": "Check my stuck agents"}, "next_run_at": \(now.timeIntervalSince1970 + 720), "last_run": {"state": "succeeded"}},
      {"id": "auto_bbbbbbbbbbbbbbbbbbbb", "name": "Nightly deps PR", "enabled": true, "trigger": {"type": "cron", "expr": "0 2 * * *", "tz": "local"},
       "body": {"type": "command", "command": "scripts/deps.sh"}, "next_run_at": \(now.timeIntervalSince1970 + 64800), "last_run": {"state": "failed"}},
      {"id": "auto_cccccccccccccccccccc", "name": "Clean DerivedData", "enabled": false, "trigger": {"type": "cron", "expr": "0 * * * *", "tz": "local"},
       "body": {"type": "command", "command": "rm -rf ~/Library/Developer/Xcode/DerivedData/*"}, "next_run_at": null, "last_run": null}
    ]}
    """.utf8)

    nonisolated static let cloudJSON = Data("""
    {"automations": [
      {"id": "auto_dddddddddddddddddddd", "name": "Morning brief", "enabled": true,
       "triggers": [{"id": "trg_1", "status": "active", "spec": {"type": "cron", "expr": "0 9 * * 1-5", "tz": "America/Los_Angeles"}, "next_at": 1},
                    {"id": "trg_2", "status": "active", "spec": {"type": "manual"}, "next_at": null}],
       "body": {"type": "chief", "chief": "agent_X", "conversation": "c", "prompt": "Summarize overnight mail and PRs"},
       "next_run_at": \((now.timeIntervalSince1970 + 3600) * 1000)},
      {"id": "auto_eeeeeeeeeeeeeeeeeeee", "name": "Weekly changelog", "enabled": true,
       "triggers": [{"spec": {"type": "cron", "expr": "0 17 * * 5", "tz": "America/Los_Angeles"}}],
       "body": {"type": "chief", "chief": "agent_X", "conversation": "c", "prompt": "Post the week's changelog"},
       "next_run_at": \((now.timeIntervalSince1970 + 3 * 86400) * 1000)}
    ]}
    """.utf8)

    struct Offline: Error {}

    @Test func absentAutomationActionsAreExplicitlyUnavailable() {
        // The real AutomationsHostingView currently has no operation bindings. Its page must
        // never offer clickable Run now / Pause / Edit buttons that silently do nothing.
        let actions = AutomationsPageView.Actions()
        #expect(actions.new == nil)
        #expect(actions.runNow == nil)
        #expect(actions.setEnabled == nil)
        #expect(actions.edit == nil)
    }

    @Test func bothSourcesLoadIntoOneGroupedList() async {
        let page = AutomationsPage(local: { Self.localJSON }, cloud: { Self.cloudJSON })
        await page.reload(now: Self.now)
        #expect(page.rows.count == 5)
        let sections = page.sections(now: Self.now)
        #expect(sections.map(\.0) == [.needsYou, .today, .later, .paused])
        #expect(sections[0].1.map(\.name) == ["Nightly deps PR"])
        #expect(sections[1].1.map(\.name) == ["Unblock agents", "Morning brief"])
        #expect(sections[2].1.map(\.name) == ["Weekly changelog"])
        #expect(sections[3].1.map(\.name) == ["Clean DerivedData"])
        #expect(page.rows.first { $0.name == "Morning brief" }?.target == .cloud)
        #expect(page.rows.first { $0.name == "Morning brief" }?.schedule == "cron 0 9 * * 1-5 (America/Los_Angeles)")
        #expect(page.badgeCount == 1, "the badge counts failures only")
    }

    @Test func aLocalTriggerReadsAsTheCLISaysIt() {
        // `cmux automation create review --when pr-opened` lists its trigger in words.
        let json = Data(#"{"automations": [{"id": "auto_ffffffffffffffffffff", "name": "Review PRs", "enabled": true, "trigger": {"type": "event", "event": "pr-opened", "debounce_seconds": 5}, "trigger_label": "When a pull request is opened", "body": {"type": "prompt", "prompt": "Review it"}}]}"#.utf8)
        #expect(AutomationRow.local(json).first?.schedule == "When a pull request is opened")
    }

    @Test func aSourceThatFailsKeepsTheOthersRowsAndSaysWhy() async {
        let page = AutomationsPage(local: { Self.localJSON }, cloud: { throw Offline() })
        await page.reload(now: Self.now)
        #expect(page.rows.count == 3)
        #expect(page.problems[.cloud] == "unreachable")
        #expect(page.problems[.thisMac] == nil)
        #expect(AutomationStrings().problem(.cloud, code: "automation.signed_out").contains("Sign in"))
        let signedOut = AutomationsPage(local: { Self.localJSON }, cloud: { throw AutomationsPageHost.SourceError(code: "automation.signed_out", message: "") })
        await signedOut.reload(now: Self.now)
        #expect(signedOut.problems[.cloud] == "automation.signed_out")
    }

    @Test func selectionFollowsTheRows() async {
        let page = AutomationsPage(local: { Self.localJSON }, cloud: { Data() })
        await page.reload(now: Self.now)
        #expect(page.selected != nil)
        page.selection = "auto_missing"
        await page.reload(now: Self.now)
        #expect(page.selected?.id == page.rows.first?.id)
    }

    /// Renders the page in a light and a dark theme, side by side, to one PNG.
    @Test func rendersLightAndDark() async throws {
        let page = AutomationsPage(local: { Self.localJSON }, cloud: { Self.cloudJSON })
        await page.reload(now: Self.now)
        page.selection = "auto_dddddddddddddddddddd"
        if let i = page.rows.firstIndex(where: { $0.id == "auto_dddddddddddddddddddd" }) {
            var row = page.rows[i]
            row.last = .succeeded
            row.runs = [
                .init(id: "run_1", at: Self.now.addingTimeInterval(-86400 + 3600), result: .succeeded),
                .init(id: "run_2", at: Self.now.addingTimeInterval(-2 * 86400 + 3600), result: .succeeded, reason: "Cloud (Mac asleep)"),
                .init(id: "run_3", at: Self.now.addingTimeInterval(-3 * 86400 + 13300), result: .succeeded, lateSeconds: 9720),
                .init(id: "run_4", at: Self.now.addingTimeInterval(-4 * 86400 + 3600), result: .failed, reason: "exit_1"),
            ]
            let rows = page.rows.enumerated().map { $0.offset == i ? row : $0.element }
            let shown = AutomationsPage(rows: rows, selection: row.id)
            let light = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1D1D1F)))
            let dark = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x1E1E20), foreground: ThemeRGB(hex: 0xF2F2F7)))
            let view = HStack(spacing: 24) {
                AutomationsPageView(page: shown, palette: AutomationsPalette(tokens: light), now: Self.now)
                    .frame(width: 760, height: 440).environment(\.colorScheme, .light)
                AutomationsPageView(page: shown, palette: AutomationsPalette(tokens: dark), now: Self.now)
                    .frame(width: 760, height: 440).environment(\.colorScheme, .dark)
            }
            .padding(24).background(Color.gray)
            // ImageRenderer draws no ScrollView content; a hosting view draws what the app draws.
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 1592, height: 488)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            #expect(png.count > 10_000)
            let out = ProcessInfo.processInfo.environment["CMUX_AUTOMATIONS_SHOTS"].map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent() // Tests/CmuxNextCloudUITests
                .appendingPathComponent("../../../../../.build/artifacts/automations-page.png").standardized
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: out)
        }
    }
}

/// The page as a working surface (docs/automations-desktop-parity.md): each automation's runs from
/// `history --json` with their chat or log, failures unread until seen, a stopped runner said, and
/// every button and the form running the same CLI words a person or the Chief would type.
@MainActor @Suite(.serialized) struct AutomationsPageActionTests {
    nonisolated static let t0: Double = 1_793_350_800

    nonisolated static let list = Data("""
    {"automations": [
      {"id": "auto_aaaaaaaaaaaaaaaaaaaa", "name": "Brief", "enabled": true, "trigger": {"type": "cron", "expr": "0 9 * * 1-5", "tz": "local"},
       "trigger_label": "cron 0 9 * * 1-5 (local)", "timeout_seconds": 1800,
       "body": {"type": "prompt", "prompt": "Summarize my PRs", "folder": "/Users/me/code"}, "next_run_at": \(t0 + 3600),
       "last_run": {"state": "failed", "reason": "needs_permission"}, "seen_at": \(t0 - 100), "unread_failures": 1},
      {"id": "auto_bbbbbbbbbbbbbbbbbbbb", "name": "Disk check", "enabled": true, "trigger": {"type": "every", "seconds": 600},
       "body": {"type": "command", "command": "df -h"}, "next_run_at": \(t0 + 600), "last_run": {"state": "succeeded"}, "seen_at": 0, "unread_failures": 0}
    ], "runner": {"health": "stopped", "running": false}}
    """.utf8)

    nonisolated static let history = Data("""
    {"runs": [
      {"id": "run_new", "automation": "auto_aaaaaaaaaaaaaaaaaaaa", "trigger": "schedule", "state": "failed", "reason": "needs_permission",
       "created_at": \(t0), "started_at": \(t0), "finished_at": \(t0 + 30), "late_seconds": 0, "session": "auto-aaaaaaaa-new00000", "log_path": "/tmp/run_new.log"},
      {"id": "run_old", "automation": "auto_aaaaaaaaaaaaaaaaaaaa", "trigger": "schedule", "state": "failed", "reason": "exit_7",
       "created_at": \(t0 - 86400), "started_at": \(t0 - 86400), "finished_at": \(t0 - 86390), "late_seconds": 7200, "attempt": 1, "log_path": "/tmp/run_old.log"},
      {"id": "run_skip", "automation": "auto_aaaaaaaaaaaaaaaaaaaa", "trigger": "schedule", "state": "skipped", "reason": "machine_asleep",
       "created_at": \(t0 - 2 * 86400), "scheduled_at": \(t0 - 2 * 86400), "late_seconds": 0},
      {"id": "run_ok", "automation": "auto_bbbbbbbbbbbbbbbbbbbb", "trigger": "schedule", "state": "succeeded",
       "created_at": \(t0 - 60), "started_at": \(t0 - 60), "finished_at": \(t0 - 59), "late_seconds": 0, "log_path": "/tmp/run_ok.log"}
    ]}
    """.utf8)

    /// Records the CLI words; refuses the ones `refuse` matches.
    nonisolated final class FakeCLI: @unchecked Sendable {
        var calls: [[String]] = []
        var refuse: ([String]) -> Bool = { _ in false }
        func run(_ words: [String]) throws -> Data {
            calls.append(words)
            if refuse(words) { throw AutomationsPageHost.SourceError(code: "cli_failed", message: "an automation named \"Brief\" already exists") }
            if words.starts(with: ["automation", "create"]) { return Data(#"{"id": "auto_cccccccccccccccccccc"}"#.utf8) }
            if words.starts(with: ["automation", "logs"]) { return Data(#"{"log": "line 1\nline 2\n"}"#.utf8) }
            return Data("{}".utf8)
        }
    }

    func page(_ fake: FakeCLI) -> AutomationsPage {
        AutomationsPage(local: { Self.list }, cloud: { Data() }, history: { Self.history }, cli: { words in try fake.run(words) })
    }

    @Test func cloudCommandRunsShowWithTheirReasonAndTheirMachineLog() async throws {
        let cloudList = Data("""
        {"automations": [{"id": "auto_cccccccccccccccccccc", "name": "models-scout", "enabled": true,
          "description": "Cloud command made with cmux automation: bash scripts/models/run-scout.sh",
          "triggers": [{"spec": {"type": "cron", "expr": "0 1,7,13,19 * * *", "tz": "UTC"}}, {"spec": {"type": "manual"}}],
          "body": {"type": "steps", "steps": []}, "next_run_at": \((Self.t0 + 3600) * 1000)}]}
        """.utf8)
        let cloudRuns = Data("""
        {"runs": [
          {"id": "run_c2", "automation": "auto_cccccccccccccccccccc", "state": "failed", "created_at": \(Self.t0 * 1000),
           "started_at": \(Self.t0 * 1000), "finished_at": \((Self.t0 + 90) * 1000), "trigger": {"type": "cron", "scheduled_at": \(Self.t0 * 1000)},
           "error": {"code": "machine.exit", "message": "step 1: exit 3: error: 2 tests failed"}},
          {"id": "run_c1", "automation": "auto_cccccccccccccccccccc", "state": "succeeded", "created_at": \((Self.t0 - 21600) * 1000),
           "started_at": \((Self.t0 - 21600) * 1000), "finished_at": \((Self.t0 - 21000) * 1000), "trigger": {"type": "manual"}}
        ], "next_cursor": null}
        """.utf8)
        let fake = FakeCLI()
        let page = AutomationsPage(local: { Self.list }, cloud: { cloudList }, history: { Self.history }, cloudHistory: { cloudRuns },
                                   cli: { words in try fake.run(words) })
        await page.reload(now: Date(timeIntervalSince1970: Self.t0))
        let scout = try #require(page.rows.first { $0.name == "models-scout" })
        #expect(scout.target == .cloud && scout.kind == .command && scout.task == "bash scripts/models/run-scout.sh")
        #expect(scout.runs.map(\.id) == ["run_c2", "run_c1"])
        #expect(scout.last == .failed && scout.needsYou, "its newest run failed")
        #expect(scout.runs[0].reason == "step 1: exit 3: error: 2 tests failed")
        #expect(scout.runs[0].trigger == "schedule" && scout.runs[1].trigger == "manual")
        #expect(scout.runs[0].logPath != nil, "a Cloud command run has a log on its machine")
        await page.toggleLog(scout.runs[0])
        #expect(fake.calls.last == ["automation", "logs", "run_c2", "--target", "cloud"])
        #expect(page.shownLog?.run == "run_c2")
    }

    @Test func showByNameSelectsItAndOpensItsNewestLog() async throws {
        let fake = FakeCLI()
        let page = page(fake)
        #expect(await page.show(named: "disk CHECK", now: Date(timeIntervalSince1970: Self.t0)))
        #expect(page.selection == "auto_bbbbbbbbbbbbbbbbbbbb")
        #expect(page.shownLog?.run == "run_ok" && page.shownLog?.text == "line 1\nline 2")
        #expect(await page.show(named: "auto_aaaaaaaaaaaaaaaaaaaa"))
        #expect(page.selection == "auto_aaaaaaaaaaaaaaaaaaaa" && page.shownLog?.run == "run_new")
        #expect(await page.show(named: "auto_aaaaaaaaaaaaaaaaaaaa"), "a second show keeps the log open")
        #expect(page.shownLog?.run == "run_new")
        #expect(!(await page.show(named: "Nope")))
        #expect(page.selection == "auto_aaaaaaaaaaaaaaaaaaaa")
    }

    @Test func runsJoinTheirAutomationWithChatLogUnreadAndWords() async throws {
        let fake = FakeCLI()
        let page = page(fake)
        await page.reload(now: Date(timeIntervalSince1970: Self.t0))
        let brief = try #require(page.rows.first { $0.name == "Brief" })
        #expect(brief.runs.map(\.id) == ["run_new", "run_old", "run_skip"], "newest first")
        #expect(brief.runs[0].session == "auto-aaaaaaaa-new00000")
        #expect(brief.runs[0].result == .needsYou)
        #expect(brief.runs[0].unread, "a failure after the last look is unread")
        #expect(!brief.runs[1].unread, "a failure before the last look is read")
        #expect(brief.runs[1].attempt == 1)
        #expect(brief.last == .needsYou && brief.needsYou && brief.unread == 1)
        #expect(brief.kind == .prompt && brief.folder == "/Users/me/code")
        #expect(page.rows.first { $0.name == "Disk check" }?.kind == .command)
        #expect(page.runner == .stopped)
        #expect(page.sections(now: Date(timeIntervalSince1970: Self.t0)).first?.0 == .needsYou)
        let strings = AutomationStrings()
        #expect(strings.reason("exit_7") == "Exited with code 7")
        #expect(strings.reason("machine_asleep") == "Skipped: this Mac was asleep")
        #expect(strings.reason("needs_permission") == "Stopped to ask for your approval")
        #expect(strings.reason("start_failed: No such file") == "Could not start")
        #expect(strings.reason("something_new") == "something_new")
    }

    @Test func buttonsRunTheCLIWordsAndCloudRowsGoToTheCloud() async throws {
        let fake = FakeCLI()
        let page = page(fake)
        await page.reload(now: .now)
        let brief = try #require(page.rows.first { $0.name == "Brief" })
        await page.runNow(brief)
        await page.setEnabled(brief, false)
        await page.markSeen(brief)
        #expect(fake.calls.contains(["automation", "run", brief.id]))
        #expect(fake.calls.contains(["automation", "pause", brief.id]))
        #expect(fake.calls.contains(["automation", "seen", brief.id]))
        #expect(page.rows.first { $0.id == brief.id }?.unread == 0)
        await page.startRunner()
        #expect(fake.calls.contains(["automation", "runner", "install"]))
        var cloud = brief
        cloud.target = .cloud
        #expect(AutomationsPage.words("run", cloud) == ["automation", "run", brief.id, "--target", "cloud"])
        await page.toggleLog(brief.runs[1])
        #expect(page.shownLog?.run == "run_old" && page.shownLog?.text == "line 1\nline 2")
        page.confirmingDelete = brief.id
        await page.delete(brief)
        #expect(fake.calls.contains(["automation", "delete", brief.id, "--yes"]))
        #expect(page.confirmingDelete == nil)
    }

    @Test func aRefusedCommandSaysWhyAndTheFormStaysOpen() async {
        let fake = FakeCLI()
        fake.refuse = { $0.starts(with: ["automation", "create"]) }
        let page = page(fake)
        page.draft = AutomationDraft(name: "Brief", task: "Summarize")
        await page.save()
        #expect(page.draft != nil, "a refused save keeps what the person typed")
        #expect(page.actionError?.contains("already exists") == true)
        fake.refuse = { _ in false }
        page.draft?.name = "Brief 2"
        await page.save()
        #expect(page.draft == nil)
        #expect(page.selection == "auto_cccccccccccccccccccc", "the new automation is selected")
        #expect(page.actionError == nil)
    }

    @Test func theFormMakesTheCreateAndEditWords() throws {
        var draft = AutomationDraft(name: " Brief ", task: "Summarize my PRs", folder: "~/code", schedule: .weekdays(hour: 9, minute: 5))
        #expect(draft.problems.isEmpty)
        #expect(draft.arguments == ["automation", "create", "Brief", "--prompt", "Summarize my PRs", "--folder", "~/code",
                                    "--weekdays", "09:05", "--timeout", "30m"])
        draft.schedule = .weekly(weekday: 5, hour: 17, minute: 0)
        #expect(draft.arguments.contains("fri 17:00"))
        draft.cloud = true
        #expect(draft.arguments.suffix(2) == ["--target", "cloud"])
        #expect(!draft.arguments.contains("--folder"), "a Cloud prompt runs in the Cloud Chief's chat, in no folder")
        draft.isCommand = true
        #expect(draft.problems.isEmpty, "a Cloud command runs on a Cloud machine")
        #expect(draft.arguments == ["automation", "create", "Brief", "--command", "Summarize my PRs", "--folder", "~/code",
                                    "--weekly", "fri 17:00", "--timeout", "30m", "--target", "cloud"])
        #expect(AutomationDraft(task: "x").problems == [.nameMissing])
        #expect(AutomationDraft(name: "x", task: "y", schedule: .every(minutes: 0)).problems == [.intervalTooShort])

        // Edit: the fields come back from the row, presets as presets.
        let row = AutomationRow(id: "auto_x", name: "Disk", target: .thisMac, schedule: "", task: "df -h", enabled: true,
                                nextRun: nil, last: .none, kind: .command, folder: "/tmp",
                                trigger: ["type": .string("cron"), "expr": .string("30 8 * * *")], timeoutSeconds: 600)
        let edit = AutomationDraft(editing: row)
        #expect(edit.isCommand && edit.folder == "/tmp" && edit.timeoutMinutes == 10)
        #expect(edit.schedule == .daily(hour: 8, minute: 30))
        #expect(edit.arguments.prefix(5) == ["automation", "edit", "auto_x", "--name", "Disk"])
        #expect(AutomationDraft.schedule(of: ["type": .string("cron"), "expr": .string("0 * * * *")]) == .hourly)
        #expect(AutomationDraft.schedule(of: ["type": .string("cron"), "expr": .string("0 9 * * 1-5")]) == .weekdays(hour: 9, minute: 0))
        #expect(AutomationDraft.schedule(of: ["type": .string("cron"), "expr": .string("0 9 1 * *")]) == .cron("0 9 1 * *"))
        #expect(AutomationDraft.schedule(of: ["type": .string("every"), "seconds": .number(1800)]) == .every(minutes: 30))
        #expect(AutomationDraft.schedule(of: ["type": .string("event")]) == .unchanged)
        #expect(!AutomationDraft(editing: AutomationRow(id: "auto_e", name: "E", target: .thisMac, schedule: "", task: "t", enabled: true,
                                                        nextRun: nil, last: .none, trigger: ["type": .string("event")])).arguments
            .contains { $0.hasPrefix("--") && ["--manual", "--cron", "--daily"].contains($0) }, "an event trigger is left as it is")
    }

    /// The detail with its runs and the form, light and dark, to PNGs for review
    /// (`$CMUX_AUTOMATIONS_SHOTS` folder, else the repository's `.build/artifacts/`).
    @Test func rendersRunsRunnerLineAndForm() async throws {
        let fake = FakeCLI()
        let page = page(fake)
        let now = Date(timeIntervalSince1970: Self.t0 + 120)
        await page.reload(now: now)
        page.selection = "auto_aaaaaaaaaaaaaaaaaaaa"
        await page.toggleLog(try #require(page.selected?.runs[1]))
        let light = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1D1D1F)))
        let dark = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x1E1E20), foreground: ThemeRGB(hex: 0xF2F2F7)))
        let actions = AutomationsPageView.Actions(openChat: { _, _ in })
        func shot(_ name: String) throws {
            let view = HStack(spacing: 24) {
                AutomationsPageView(page: page, palette: AutomationsPalette(tokens: light), now: now, actions: actions)
                    .frame(width: 880, height: 560).environment(\.colorScheme, .light)
                AutomationsPageView(page: page, palette: AutomationsPalette(tokens: dark), now: now, actions: actions)
                    .frame(width: 880, height: 560).environment(\.colorScheme, .dark)
            }
            .padding(24).background(Color.gray)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 1832, height: 608)
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            #expect(png.count > 10_000)
            let dir = ProcessInfo.processInfo.environment["CMUX_AUTOMATIONS_SHOTS"].map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../../../.build/artifacts").standardized
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: dir.appendingPathComponent(name))
        }
        try shot("automations-runs.png")
        page.draft = AutomationDraft(name: "Morning brief", task: "Summarize overnight PRs and failed CI; say only what needs me.",
                                     folder: "~/code/app", schedule: .weekdays(hour: 9, minute: 0))
        try shot("automations-form.png")
    }
}

/// The page follows a theme change (a light app theme after a dark one): ThemeScope tells views through
/// `viewDidChangeEffectiveAppearance`, and the page's view then draws in the scope's new tokens.
@MainActor @Suite struct AutomationsPageThemeTests {
    final class Theme { var tokens: ThemeTokens; init(_ t: ThemeTokens) { tokens = t } }

    @Test func aThemeChangeRedrawsThePageInTheNewColors() throws {
        let dark = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x1E1E20), foreground: ThemeRGB(hex: 0xF2F2F7)))
        let light = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1D1D1F)))
        let theme = Theme(dark)
        let host = AutomationsPageHost(local: { Data() }, cloud: { Data() })
        let view = try #require(host.makeView(tokens: { theme.tokens }) as? AutomationsHostingView)
        #expect(view.palette == AutomationsPalette(tokens: dark))
        theme.tokens = light
        view.viewDidChangeEffectiveAppearance()
        #expect(view.palette == AutomationsPalette(tokens: light))
    }
}
