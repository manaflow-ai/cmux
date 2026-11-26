import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// The palette as a way into Settings (Leo 2026-11-22: "SURELY A FUCKING SETTINGS PAGE IS A
/// SOLVABLE PROBLEM"): every setting row the palette finds by name also opens the Settings page at
/// that row. Cmd-Return (Show in Settings) on a row that edits in place; Return on a row the palette
/// has no values for (a list), which only the Settings page edits.
@MainActor
struct PaletteShowInSettingsTests {
    @MainActor private final class Source: PaletteSettingsSource {
        var revealed: [String] = []
        var revealsInSettings = true
        var rows: [PaletteSettingRow] = [
            PaletteSettingRow(id: "files.hidden", title: "Hidden Files", group: "Files", value: "Off", kind: .toggle(isOn: false)),
            PaletteSettingRow(id: "terminal.fontSize", title: "Font Size", group: "Terminal Font", value: "13 pt",
                              kind: .options([PaletteSettingOption(id: "13", title: "13 pt", isCurrent: true)])),
            PaletteSettingRow(id: "notifications.soundRules", title: "Notification Sounds", group: "Notifications", value: "",
                              kind: .options([])),
        ]
        func preview(row: String, option: String?) {}
        func commit(row: String, option: String) {}
        func commit(row: String, text: String) {}
        func reveal(row: String) { revealed.append(row) }
    }

    private static func item(_ id: String, _ source: Source) -> PaletteItem? {
        SettingsPaletteProvider(source: source, showsItemsForEmptyQuery: true).makeItems().first { $0.id == "setting:\(id)" }
    }

    private static func run(_ command: PaletteCommand?) {
        guard case .perform(let run)? = command?.effect.resolved() else {
            Issue.record("Show in Settings does not perform")
            return
        }
        run()
    }

    @Test func cmdReturnOnARowThatEditsInPlaceOpensSettingsAtIt() {
        let source = Source()
        for id in ["files.hidden", "terminal.fontSize"] {
            let item = Self.item(id, source)
            #expect(item?.alternate?.title == PaletteStrings.showInSettings, "\(id)")
            #expect(item?.primary.id != "showInSettings", "\(id) still edits in place on Return")
            #expect(item?.allCommands.contains { $0.id == "showInSettings" } == true, "\(id) in the Actions menu")
            Self.run(item?.alternate)
        }
        #expect(source.revealed == ["files.hidden", "terminal.fontSize"])
    }

    @Test func returnOnARowWithNoValuesOpensSettingsAtIt() {
        let source = Source()
        let item = Self.item("notifications.soundRules", source)
        #expect(item?.primary.title == PaletteStrings.showInSettings)
        #expect(item?.alternate == nil)
        #expect(item?.actionRefs == [PaletteActionRef("openSettings", arguments: ["setting": .string("notifications.soundRules")],
                                                      title: PaletteStrings.showInSettings)])
        Self.run(item?.primary)
        #expect(source.revealed == ["notifications.soundRules"])
    }

    /// A toggle's headless primary stays its toggle; Show in Settings follows it.
    @Test func aToggleKeepsItsToggleAsTheFirstRef() {
        let refs = Self.item("files.hidden", Source())?.actionRefs.map(\.action)
        #expect(refs == ["palette.toggleSetting", "openSettings"])
    }

    @Test func aSourceWithNoSettingsPageOffersNoShowInSettings() {
        let source = Source()
        source.revealsInSettings = false
        let items = SettingsPaletteProvider(source: source, showsItemsForEmptyQuery: true).makeItems()
        #expect(!items.flatMap(\.allCommands).contains { $0.id == "showInSettings" })
    }
}
