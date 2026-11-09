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

/// The whole app's font leads Change Font… and ranks as a command (Leo 2026-11-08: "there's no
/// whole app font change thing ... i wanna just be able to see different fonts just like how i can
/// see different themes as preview"): its values draw in their own face and the highlight previews.
@MainActor
struct PaletteAppFontTests {
    @MainActor private final class Source: PaletteSettingsSource {
        var previews: [String?] = []
        var rows: [PaletteSettingRow] = [
            PaletteSettingRow(id: "terminal.fontFamily", title: "Font Family", group: "Terminal Font", value: "Menlo",
                              kind: .options([PaletteSettingOption(id: "\"Menlo\"", title: "Menlo", isCurrent: true, fontFamily: "Menlo")]),
                              isFontFamily: true),
            PaletteSettingRow(id: "appearance.font", title: "App Font", group: "Density and Motion", value: "System (default)",
                              kind: .options([
                                  PaletteSettingOption(id: "\"system\"", title: "System (default)", isCurrent: true, fontFamily: "system"),
                                  PaletteSettingOption(id: "\"Georgia\"", title: "Georgia", fontFamily: "Georgia"),
                              ]), isFontFamily: true, isAppFont: true),
        ]
        func preview(row: String, option: String?) { previews.append(option) }
        func commit(row: String, option: String) {}
        func commit(row: String, text: String) {}
    }

    @Test func theAppFontLeadsChangeFontAndIsNotDemoted() {
        let items = SettingsPaletteProvider(source: Source(), showsItemsForEmptyQuery: true).makeItems()
        #expect(items.first { $0.id == "setting:appearance.font" }?.isDemoted == false)
        #expect(items.first { $0.id == "setting:terminal.fontFamily" }?.isDemoted == true)
        guard case .push(let page)? = items.first(where: { $0.id == "settings:changeFont" })?.primary.effect else {
            Issue.record("Change Font… pushes no page")
            return
        }
        let listed = (page.providers.first as? StaticPaletteProvider)?.itemsList.map(\.id)
        #expect(listed == ["setting:appearance.font", "setting:terminal.fontFamily"])
    }

    @Test func eachAppFontPreviewsAsTheHighlightMoves() {
        let source = Source()
        guard case .options(let options, let custom) = source.rows[1].kind else { return }
        let page = SettingsPaletteProvider.valuesPage(source.rows[1], options, custom, source)
        let items = (page.providers.first as? StaticPaletteProvider)?.itemsList ?? []
        #expect(items.map(\.fontFamily) == ["system", "Georgia"])
        page.onHighlight?(items[1])
        page.onLeave?()
        #expect(source.previews == ["\"Georgia\"", nil])
    }
}
