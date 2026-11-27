import Foundation

/// The rows Cmd-P and Cmd-Shift-P put first when the query names a path or a
/// web address: Open it, and Ask Agent about it. The other results follow.
struct GoToPaletteRows {
    var parser = PaletteQueryTargetParser()

    static var section: PaletteSection {
        PaletteSection(id: "goTo", title: PaletteStrings.sectionGoTo, order: -200)
    }

    /// The rows for `query`, empty when it names no place.
    @MainActor
    func items(_ query: String, source: (any PaletteGoToSource)?) -> [PaletteItem] {
        guard let source, let match = parser.parse(query, base: source.baseDirectory()) else { return [] }
        return Self.items(match, source: source)
    }

    /// The rows for `match` (pure; the tests call it).
    @MainActor
    static func items(_ match: PaletteQueryMatch, source: (any PaletteGoToSource)?) -> [PaletteItem] {
        let target = match.target
        let openSymbol: String
        let openAccessory: String
        var openSubtitle: String?
        switch target {
        case .file:
            openSymbol = "doc.text"
            openAccessory = PaletteStrings.kindFile
        case .folder:
            openSymbol = "folder"
            openAccessory = PaletteStrings.kindFolder
            openSubtitle = PaletteStrings.goToFolderHint
        case .web:
            openSymbol = "globe"
            openAccessory = PaletteStrings.kindBrowser
        }
        let open = PaletteCommand(id: "goTo.open", title: PaletteStrings.open, symbol: "return", effect: .perform { [weak source] in
            source?.open(target)
        })
        let prompt = match.trailingText
        let ask = PaletteCommand(id: "goTo.ask", title: PaletteStrings.goToAskCommand, symbol: "bubble.left.and.text.bubble.right",
                                 effect: .perform { [weak source] in source?.askAgent(about: target, prompt: prompt) })
        let copy = PaletteCommand(id: "goTo.copy", title: target.workingDirectory == nil ? PaletteStrings.goToCopyURL : PaletteStrings.copyPath,
                                  symbol: "doc.on.doc", effect: .perform { PaletteClipboard.copy(target.display) })
        var openItem = PaletteItem(id: "goTo:open", title: PaletteStrings.goToOpen(target.display), subtitle: openSubtitle,
                                   accessory: openAccessory, symbol: openSymbol, section: section, primary: open,
                                   alternate: ask, secondary: [copy], frecencyKey: nil)
        openItem.keywords = [query(match)]
        let askTitle = prompt.map { PaletteStrings.goToAskWithPrompt(target.display, $0) } ?? PaletteStrings.goToAsk(target.display)
        var askItem = PaletteItem(id: "goTo:ask", title: askTitle,
                                  subtitle: prompt == nil ? PaletteStrings.goToAskHint : PaletteStrings.goToAskSendsHint,
                                  accessory: PaletteStrings.kindAgentChat, symbol: "bubble.left.and.text.bubble.right",
                                  section: section, primary: ask, secondary: [copy], frecencyKey: nil)
        askItem.keywords = [query(match)]
        // With words after the place, asking is what the user most likely wants.
        return prompt == nil ? [openItem, askItem] : [askItem, openItem]
    }

    private static func query(_ match: PaletteQueryMatch) -> String {
        [match.target.display, match.trailingText].compactMap { $0 }.joined(separator: " ")
    }
}
