import Foundation

/// The font picker's page: one target's families, each drawn in its own face, the default and the
/// fonts picked lately first, the current one selected. The page carries the tuner, so the palette
/// shows the target strip, the sample and the sliders with it (``PaletteFontTunerView``). Moving the
/// highlight previews that family with the sliders' size and line height; Return writes the three in
/// one write and closes; leaving restores every surface.
@MainActor
enum PaletteFontPage {
    static let id = "settings:fonts"

    /// The page of `tuner`'s target, opened on `query` (a target switch keeps what was typed).
    static func page(_ tuner: PaletteFontTuner, query: String = "") -> PalettePageSpec {
        let target = tuner.target
        let options = target.familyOptions
        let lately = PaletteSection(id: "fonts-recent", title: PaletteStrings.sectionRecent, order: 0)
        let all = PaletteSection(id: "fonts-all", title: PaletteStrings.fontSectionAll(target.sample), order: 1)
        let items = options.map { option in
            var item = PaletteItem(
                id: "option:\(option.id)", title: option.title,
                subtitle: tuner.style.rowsCarrySamples && option.fontFamily != nil ? PaletteFontSamples.rowSample(target.sample) : nil,
                accessory: option.isCurrent ? PaletteStrings.current : nil,
                symbol: option.isCurrent ? "checkmark" : "textformat",
                // The default (the Ghostty config's face, the terminal's) and the fonts picked lately lead.
                section: option.id == "reset" || option.isRecent ? lately : all,
                primary: PaletteCommand(id: "choose", title: PaletteStrings.useFont, symbol: "return",
                                        effect: .perform { tuner.commit(option: option.id) }),
                frecencyKey: nil
            )
            item.fontFamily = option.fontFamily
            item.subtitleInFace = true
            return item
        }
        var page = PalettePageSpec(
            id: id, title: PaletteStrings.changeFontTitle, placeholder: PaletteStrings.searchFonts(target.title), symbol: "textformat",
            providers: [StaticPaletteProvider(id: "font-families", items: items)],
            initialQuery: query,
            keepsSectionOrder: true,
            emptyQuerySelection: options.firstIndex(where: \.isCurrent) ?? 0
        )
        page.onHighlight = { item in
            guard let id = item?.id, id.hasPrefix("option:") else { return }
            tuner.highlight(option: String(id.dropFirst("option:".count)))
        }
        page.onLeave = { tuner.cancel() }
        page.fontTuner = tuner
        return page
    }
}

/// The sample texts: code for a code font (the glyphs that tell monospaced faces apart), a line of
/// prose for a reading face. Not translated: a sample shows letterforms, and code reads the same in
/// every language.
enum PaletteFontSamples {
    static func rowSample(_ sample: PaletteFontSample) -> String {
        switch sample {
        case .code: "0O 1lI {} => != ~"
        case .prose: "Aa Gg Rr 0123, the quick brown fox"
        }
    }

    static func block(_ sample: PaletteFontSample) -> String {
        switch sample {
        case .code: "fn main() { let x = 0O1lI; } // => != ~\n$ git log --oneline | head -3"
        case .prose: "The quick brown fox jumps over the lazy dog.\nSphinx of black quartz, judge my vow: 0123456789."
        }
    }
}
