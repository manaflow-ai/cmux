import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Change Font… (Cmd-Shift-P): one page of every font setting, each opening its value list, where
/// each font draws in its own face and the fonts picked lately say Recent. The highlight previews,
/// leaving reverts (the settings value page's own behavior).
@MainActor
struct PaletteChangeFontTests {
    @MainActor private final class Source: PaletteSettingsSource {
        var previews: [String?] = []
        var rows: [PaletteSettingRow] = [
            PaletteSettingRow(id: "files.hidden", title: "Hidden Files", group: "Files", value: "Off", kind: .toggle(isOn: false)),
            PaletteSettingRow(id: "terminal.fontFamily", title: "Font Family", group: "Terminal Font", value: "Menlo",
                              kind: .options([
                                  PaletteSettingOption(id: "reset", title: "Ghostty Config"),
                                  PaletteSettingOption(id: "\"Iosevka\"", title: "Iosevka", fontFamily: "Iosevka", isRecent: true),
                                  PaletteSettingOption(id: "\"Menlo\"", title: "Menlo", isCurrent: true, fontFamily: "Menlo", isRecent: true),
                                  PaletteSettingOption(id: "\"SF Mono\"", title: "SF Mono", fontFamily: "SF Mono"),
                              ]), isFontFamily: true),
            PaletteSettingRow(id: "agentPane.display.font.size", title: "Text Size", group: "Agent Chat", value: "14 pt",
                              kind: .options([PaletteSettingOption(id: "14", title: "14 pt", isCurrent: true)])),
        ]
        func preview(row: String, option: String?) { previews.append(option) }
        func commit(row: String, option: String) {}
        func commit(row: String, text: String) {}
    }

    @Test func changeFontListsOnlyTheFontSettings() {
        let provider = SettingsPaletteProvider(source: Source(), showsItemsForEmptyQuery: true)
        let items = provider.makeItems()
        let changeFont = items.first { $0.id == "settings:changeFont" }
        #expect(changeFont?.title == PaletteStrings.changeFont)
        guard case .push(let page)? = changeFont?.primary.effect else {
            Issue.record("Change Font… pushes no page")
            return
        }
        let listed = (page.providers.first as? StaticPaletteProvider)?.itemsList.map(\.id)
        #expect(listed == ["setting:terminal.fontFamily", "setting:agentPane.display.font.size"])
    }

    @Test func eachFontDrawsInItsOwnFaceAndRecentFontsSaySo() {
        let source = Source()
        guard case .options(let options, let custom) = source.rows[1].kind else { return }
        let page = SettingsPaletteProvider.valuesPage(source.rows[1], options, custom, source)
        let items = (page.providers.first as? StaticPaletteProvider)?.itemsList ?? []
        #expect(items.map(\.fontFamily) == [nil, "Iosevka", "Menlo", "SF Mono"])
        #expect(items.map(\.accessory) == [nil, PaletteStrings.sectionRecent, PaletteStrings.current, nil])
        #expect(page.emptyQuerySelection == 2)
        page.onHighlight?(items[1])
        page.onLeave?()
        #expect(source.previews == ["\"Iosevka\"", nil])
    }
}
