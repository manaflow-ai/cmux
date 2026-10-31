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

    @Test func aSourceThatFailsKeepsTheOthersRowsAndSaysWhy() async {
        let page = AutomationsPage(local: { Self.localJSON }, cloud: { throw Offline() })
        await page.reload(now: Self.now)
        #expect(page.rows.count == 3)
        #expect(page.problems[.cloud] != nil)
        #expect(page.problems[.thisMac] == nil)
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
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            #expect(png.count > 10_000)
            let out = ProcessInfo.processInfo.environment["CMUX_AUTOMATIONS_SHOTS"].map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent() // Tests/CmuxNextCloudUITests
                .appendingPathComponent("../../../../../.build/artifacts/automations-page.png").standardized
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: out)
        }
    }
}
