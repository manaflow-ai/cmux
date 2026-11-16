import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Change Font… (Cmd-Shift-P) is the font picker (Leo, 2026-11-08: "this command palette font
/// changing flow is shit"; 2026-11-14: "we wanted to make our own fucking custom fonts"): one page per
/// surface (Terminal, Chat, Markdown, ...), each font drawn in its own face, a target strip, and size
/// and line height sliders. Every step previews family, size and line height together; Return writes
/// them in one write; leaving restores everything.
@MainActor
struct PaletteChangeFontTests {
    @MainActor private final class Source: PaletteSettingsBatchSource {
        var previews: [[PaletteSettingEdit]] = []
        var ended = 0
        var commits: [[PaletteSettingEdit]] = []
        var rows: [PaletteSettingRow] = [
            PaletteSettingRow(id: "files.hidden", title: "Hidden Files", group: "Files", value: "Off", kind: .toggle(isOn: false)),
            PaletteSettingRow(id: "terminal.fontFamily", title: "Font Family", group: "Terminal Font", value: "Menlo",
                              kind: .options([
                                  PaletteSettingOption(id: "reset", title: "Ghostty Config"),
                                  PaletteSettingOption(id: "\"Iosevka\"", title: "Iosevka", fontFamily: "Iosevka", isRecent: true),
                                  PaletteSettingOption(id: "\"Menlo\"", title: "Menlo", isCurrent: true, fontFamily: "Menlo", isRecent: true),
                                  PaletteSettingOption(id: "\"SF Mono\"", title: "SF Mono", fontFamily: "SF Mono"),
                              ]), isFontFamily: true),
            PaletteSettingRow(id: "terminal.fontSize", title: "Font Size", group: "Terminal Font", value: "13 pt",
                              kind: .options([PaletteSettingOption(id: "13", title: "13 pt", isCurrent: true)]),
                              number: PaletteSettingNumber(range: 4...96, step: 1, value: 13, format: { "\(Int($0)) pt" })),
            PaletteSettingRow(id: "agentPane.display.font.ui", title: "Chat Interface Font", group: "Agent Chat", value: "System",
                              kind: .options([
                                  PaletteSettingOption(id: "\"system-ui\"", title: "System", isCurrent: true, fontFamily: ".system"),
                                  PaletteSettingOption(id: "\"verdana\"", title: "Verdana", fontFamily: "Verdana"),
                              ])),
            PaletteSettingRow(id: "agentPane.display.font.size", title: "Text Size", group: "Agent Chat", value: "14 pt",
                              kind: .options([PaletteSettingOption(id: "14", title: "14 pt", isCurrent: true)]),
                              number: PaletteSettingNumber(range: 10...28, step: 1, value: 14, format: { "\(Int($0)) pt" })),
            PaletteSettingRow(id: "agentPane.display.font.lineHeight", title: "Line Height", group: "Agent Chat", value: "163%",
                              kind: .options([]),
                              number: PaletteSettingNumber(range: 1.2...2.4, step: 0.05, value: 1.625, format: { "\($0)" })),
        ]
        func preview(row: String, option: String?) { if option == nil { ended += 1 } }
        func commit(row: String, option: String) {}
        func commit(row: String, text: String) {}
        func preview(_ edits: [PaletteSettingEdit], terminal: Bool) { previews.append(edits) }
        func commit(_ edits: [PaletteSettingEdit]) { commits.append(edits) }
    }

    private func picker(_ source: Source) throws -> (PaletteFontTuner, PalettePageSpec) {
        let provider = SettingsPaletteProvider(source: source, showsItemsForEmptyQuery: true)
        let changeFont = try #require(provider.makeItems().first { $0.id == "settings:changeFont" })
        #expect(changeFont.title == PaletteStrings.changeFont)
        guard case .push(let page) = changeFont.primary.effect.resolved() else {
            Issue.record("Change Font… pushes no page")
            throw CancellationError()
        }
        return (try #require(page.fontTuner), page)
    }

    private func items(_ page: PalettePageSpec) -> [PaletteItem] {
        (page.providers.first as? StaticPaletteProvider)?.itemsList ?? []
    }

    @Test func changeFontOpensThePickerOnTheTerminalWithItsFacesAndSliders() throws {
        let (tuner, page) = try picker(Source())
        #expect(tuner.targets.map(\.id) == ["terminal", "chat"])
        #expect(tuner.target.id == "terminal")
        #expect(tuner.size == 13)
        #expect(tuner.lineHeight == nil)
        let rows = items(page)
        #expect(rows.map(\.fontFamily) == [nil, "Iosevka", "Menlo", "SF Mono"])
        #expect(rows.map(\.accessory) == [nil, nil, PaletteStrings.current, nil])
        // The default and the recent fonts lead; the rest follow under the monospaced fonts.
        #expect(rows.map(\.section.id) == ["fonts-recent", "fonts-recent", "fonts-recent", "fonts-all"])
        #expect(page.emptyQuerySelection == 2)
    }

    @Test func familyAndSizePreviewTogetherAndLeavingRestores() throws {
        let source = Source()
        let (tuner, page) = try picker(source)
        page.onHighlight?(items(page)[2])
        #expect(source.previews.isEmpty, "the current family with the stored size changes nothing")
        page.onHighlight?(items(page)[1])
        tuner.stepSize(2)
        #expect(source.previews.last == [PaletteSettingEdit(row: "terminal.fontFamily", option: "\"Iosevka\""),
                                         PaletteSettingEdit(row: "terminal.fontSize", option: "15")])
        page.onLeave?()
        #expect(source.ended == 1)
        #expect(source.commits.isEmpty)
    }

    @Test func returnWritesFamilyAndSizeInOneWrite() throws {
        let source = Source()
        let (tuner, page) = try picker(source)
        tuner.setSize(16.4)
        #expect(tuner.size == 16)
        guard case .perform(let run) = items(page)[3].primary.effect else {
            Issue.record("a font row's Return writes nothing")
            return
        }
        run()
        #expect(source.commits == [[PaletteSettingEdit(row: "terminal.fontFamily", option: "\"SF Mono\""),
                                    PaletteSettingEdit(row: "terminal.fontSize", option: "16")]])
    }

    @Test func switchingTargetsEndsThePreviewAndStartsFromTheStoredValues() throws {
        let source = Source()
        let (tuner, _) = try picker(source)
        tuner.stepSize(1)
        #expect(tuner.selectTarget(tuner.targetIndex + 1))
        #expect(source.ended == 1)
        #expect(tuner.target.id == "chat")
        #expect(tuner.size == 14)
        #expect(tuner.lineHeight == 1.625)
        tuner.stepLineHeight(1)
        #expect(tuner.lineHeight == 1.75)
        #expect(source.previews.last == [PaletteSettingEdit(row: "agentPane.display.font.lineHeight", option: "1.75")])
        // Wraps back to the terminal; the next open starts on the target used last.
        #expect(tuner.selectTarget(tuner.targetIndex + 1))
        #expect(tuner.target.id == "terminal")
        let page = PaletteFontPage.page(tuner)
        #expect(items(page).first { $0.fontFamily == ".system" } == nil)
    }

    @Test func changeFontReopensOnTheTargetLeftLast() throws {
        let source = Source()
        let provider = SettingsPaletteProvider(source: source, showsItemsForEmptyQuery: true)
        func open() throws -> PaletteFontTuner {
            let changeFont = try #require(provider.makeItems().first { $0.id == "settings:changeFont" })
            guard case .push(let page) = changeFont.primary.effect.resolved() else { throw CancellationError() }
            return try #require(page.fontTuner)
        }
        #expect(try open().selectTarget(1))
        #expect(try open().target.id == "chat")
        let fresh = SettingsPaletteProvider(source: source, showsItemsForEmptyQuery: true)
        let changeFont = try #require(fresh.makeItems().first { $0.id == "settings:changeFont" })
        guard case .push(let page) = changeFont.primary.effect.resolved() else { throw CancellationError() }
        #expect(page.fontTuner?.target.id == "terminal")
    }

    @Test func aRowCarriesASampleInItsFaceInTheInlineLayout() throws {
        let source = Source()
        let tuner = try #require(PaletteFontTuner(rows: source.rows, source: source, style: .inline, targetID: "terminal"))
        let rows = items(PaletteFontPage.page(tuner))
        #expect(rows[1].subtitle == PaletteFontSamples.rowSample(.code))
        #expect(rows[1].subtitleInFace)
        #expect(rows[0].subtitle == nil, "the default has no face of its own to show")
    }

    @Test func numbersSnapToTheirStepAndRange() {
        let number = PaletteSettingNumber(range: 1.2...2.4, step: 0.05, value: 1.6, format: { "\($0)" })
        #expect(number.snapped(1.63) == 1.65)
        #expect(number.snapped(0) == 1.2)
        #expect(number.snapped(9) == 2.4)
        #expect(PaletteSettingEdit(row: "a", number: 13).option == "13")
        #expect(PaletteSettingEdit(row: "a", number: 1.75).option == "1.75")
    }

    @Test func withoutAFontFamilySettingChangeFontListsTheFontSettings() throws {
        @MainActor final class Plain: PaletteSettingsSource {
            var rows: [PaletteSettingRow] = [
                PaletteSettingRow(id: "markdown.font.size", title: "Font Size", group: "Markdown", value: "16 pt",
                                  kind: .options([PaletteSettingOption(id: "16", title: "16 pt", isCurrent: true)])),
            ]
            func preview(row: String, option: String?) {}
            func commit(row: String, option: String) {}
            func commit(row: String, text: String) {}
        }
        let provider = SettingsPaletteProvider(source: Plain(), showsItemsForEmptyQuery: true)
        let changeFont = try #require(provider.makeItems().first { $0.id == "settings:changeFont" })
        guard case .push(let page) = changeFont.primary.effect.resolved() else {
            Issue.record("Change Font… pushes no page")
            return
        }
        #expect(page.fontTuner == nil)
        #expect(items(page).map(\.id) == ["setting:markdown.font.size"])
    }
}
