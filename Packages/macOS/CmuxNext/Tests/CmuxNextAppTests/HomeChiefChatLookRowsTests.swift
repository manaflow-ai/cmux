import AppKit
@testable import CmuxNextActions
import CmuxNextDesign
import CmuxNextHome
@testable import CmuxNextHomeEngine
@testable import CmuxNextSettings
import CmuxNextTestSupport
import Foundation
import Testing

/// Bubble Style and Chat Colors in the Chief Settings popover's Appearance section (Leo 2026-10-20: "being
/// able to opt into themed messages and whatnot ... it's just so awkward"): the popover's picker reads and
/// writes `home.chiefBubbleStyle`, the setting Settings > Home > Chief Chat shows, and Chat Colors opens the panel.
@MainActor @Suite(.serialized) struct HomeChiefChatLookRowsTests {
    struct Harness {
        let settings: SettingsController
        let url: URL

        func savedStyle() -> String? {
            guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (root["home"] as? [String: Any])?["chiefBubbleStyle"] as? String
        }

        func until(_ condition: () -> Bool, within timeout: Duration = .seconds(5)) async {
            let deadline = ContinuousClock.now + timeout
            while !condition(), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func make(_ json: String) async throws -> Harness {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-chief-chat-look-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return Harness(settings: settings, url: url)
    }

    func popover(_ settings: SettingsController, opened: @escaping @MainActor () -> Void = {}) -> (HomeChiefSettingsView, HomeChiefChatLookRows) {
        let home = FileManager.default.temporaryDirectory.appending(path: "cnc-chief-chat-look-brain-\(UUID().uuidString)")
        let view = HomeChiefSettingsView(muxHome: home, source: HomeChiefLocalEngine(files: HomeChiefFiles(muxHome: home), connection: { nil }))
        let rows = HomeChiefChatLookRows(settings: { settings }, openColors: opened)
        rows.install(addRow: { view.addAppearanceRow($0, control: $1) })
        return (view, rows)
    }

    @Test func thePopoverShowsBubbleStyleAndChatColorsWithTheSettingsWords() async throws {
        let h = try await make("{}")
        let (view, rows) = popover(h.settings)
        #expect(!view.appearanceRows.isHidden, "the Appearance section shows once it has the rows")
        let titles = view.appearanceRows.arrangedSubviews.compactMap { row in
            (row as? NSStackView)?.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }.first
        }
        #expect(titles.contains(SettingsSchema.descriptor(for: HomeChiefBubbleStyleSetting.configPath)?.title ?? "-"))
        #expect(rows.style.itemTitles == ["iMessage", "Theme"])
        // Unset: iMessage, the default (no default flips here).
        #expect(rows.style.selectedItem?.representedObject as? String == "imessage")
        #expect(rows.style.isEnabled)
    }

    @Test func pickingThemeWritesTheSameSettingTheSettingsPageShows() async throws {
        let h = try await make("{}")
        let (_, rows) = popover(h.settings)
        rows.style.selectItem(at: 1)
        rows.picked()
        await h.until { h.settings.snapshot.homeChiefBubbleStyle == "theme" }
        #expect(h.settings.snapshot.homeChiefBubbleStyle == "theme")
        #expect(h.savedStyle() == "theme", "written to cmux.json, as Settings > Home > Bubble Style writes it")
    }

    @Test func aChangeFromSettingsShowsInThePopover() async throws {
        let h = try await make(#"{"home":{"chiefBubbleStyle":"theme"}}"#)
        let (_, rows) = popover(h.settings)
        #expect(rows.style.selectedItem?.representedObject as? String == "theme")
        try await h.settings.setSetting(at: HomeChiefBubbleStyleSetting.configPath, to: .string("imessage"), by: .user)
        await h.until { rows.style.selectedItem?.representedObject as? String == "imessage" }
        #expect(rows.style.selectedItem?.representedObject as? String == "imessage")
    }

    @Test func chatColorsOpensThePanel() async throws {
        let h = try await make("{}")
        var opened = 0
        let (_, rows) = popover(h.settings, opened: { opened += 1 })
        rows.colors.performClick(nil)
        #expect(opened == 1)
    }
}
