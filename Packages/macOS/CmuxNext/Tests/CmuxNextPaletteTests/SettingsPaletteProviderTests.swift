import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextPalette
import Testing

/// Settings in the palette (R93): every schema setting becomes a row. A
/// toggle flips in place; a choice, number or color opens its value list,
/// where moving the highlight previews live, Return commits and leaving
/// reverts. Colors draw their real color (R98).
@MainActor @Suite struct SettingsPaletteProviderTests {
    final class Source: PaletteSettingsSource {
        var rows: [PaletteSettingRow]
        var previews: [String?] = []
        var commits: [String] = []
        var texts: [String] = []

        init(rows: [PaletteSettingRow]) { self.rows = rows }

        func preview(row: String, option: String?) { previews.append(option.map { "\(row)=\($0)" }) }
        func commit(row: String, option: String) { commits.append("\(row)=\(option)") }
        func commit(row: String, text: String) { texts.append("\(row)=\(text)") }
    }

    private let red = ThemeRGB(hex: 0xFF0000)

    private func rows() -> [PaletteSettingRow] {
        [
            PaletteSettingRow(id: "sidebar.border", title: "Sidebar Border", group: "Sidebar", value: "Off", kind: .toggle(isOn: false)),
            PaletteSettingRow(id: "layout.paneSeparation", title: "Separation", group: "Panes", value: "Borders", kind: .options([
                PaletteSettingOption(id: "none", title: "None"),
                PaletteSettingOption(id: "dividers", title: "Dividers"),
                PaletteSettingOption(id: "borders", title: "Borders", isCurrent: true),
            ])),
            PaletteSettingRow(id: "layout.paneBorderColor", title: "Border Color", group: "Panes", value: "Theme", kind: .options([
                PaletteSettingOption(id: "reset", title: "Theme Color", isCurrent: true),
                PaletteSettingOption(id: "#FF0000", title: "#FF0000", swatches: [red]),
            ], customInput: PaletteSettingCustomInput(placeholder: "#RRGGBB", isValid: { $0.hasPrefix("#") }))),
        ]
    }

    private func item(_ provider: SettingsPaletteProvider, _ id: String) throws -> PaletteItem {
        try #require(provider.makeItems().first { $0.id == "setting:\(id)" })
    }

    @Test func aToggleFlipsInPlace() throws {
        let source = Source(rows: rows())
        let provider = SettingsPaletteProvider(source: source, showsItemsForEmptyQuery: true)
        let toggle = try item(provider, "sidebar.border")
        #expect(toggle.accessory == "Off")
        guard case .performKeepingOpen(let run) = toggle.primary.effect else {
            Issue.record("a toggle keeps the palette open")
            return
        }
        run()
        #expect(source.commits == ["sidebar.border=on"])
    }

    @Test func aChoicePreviewsWhileMovingCommitsOnReturnAndRevertsOnLeave() throws {
        let source = Source(rows: rows())
        let provider = SettingsPaletteProvider(source: source, showsItemsForEmptyQuery: true)
        let row = try item(provider, "layout.paneSeparation")
        #expect(row.accessory == "Borders")
        guard case .push(let page) = row.primary.effect.resolved() else {
            Issue.record("a choice opens its value list")
            return
        }
        #expect(page.emptyQuerySelection == 2, "the current value is selected")
        let options = try #require((page.providers.first as? StaticPaletteProvider)?.itemsList)
        #expect(options.map(\.title) == ["None", "Dividers", "Borders"])
        page.onHighlight?(options[0])
        page.onHighlight?(options[1])
        page.onLeave?()
        #expect(source.previews == ["layout.paneSeparation=none", "layout.paneSeparation=dividers", nil])
        guard case .perform(let choose) = options[1].primary.effect else {
            Issue.record("choosing closes the palette")
            return
        }
        choose()
        #expect(source.commits == ["layout.paneSeparation=dividers"])
    }

    @Test func aColorDrawsSwatchesAndTakesAHexValue() throws {
        let source = Source(rows: rows())
        let provider = SettingsPaletteProvider(source: source, showsItemsForEmptyQuery: true)
        guard case .push(let page) = try item(provider, "layout.paneBorderColor").primary.effect.resolved() else {
            Issue.record("a color opens its swatch list")
            return
        }
        let options = try #require((page.providers.first as? StaticPaletteProvider)?.itemsList)
        #expect(options.first { $0.title == "#FF0000" }?.swatches == [red])
        let custom = try #require(options.last)
        guard case .textInput(let spec) = custom.primary.effect else {
            Issue.record("the last row types a custom value")
            return
        }
        #expect(spec.isValid("#00FF00"))
        #expect(!spec.isValid("green"))
        _ = spec.next?("#00FF00")
        #expect(source.texts == ["layout.paneBorderColor=#00FF00"])
    }
}
