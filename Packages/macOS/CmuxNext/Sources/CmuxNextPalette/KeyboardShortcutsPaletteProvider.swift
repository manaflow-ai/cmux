public import CmuxNextActions

/// "Search Keyboard Shortcuts": every action with a shortcut, searchable by
/// title or by shortcut words ("cmd shift p", "⌘D").
public final class KeyboardShortcutsPaletteProvider: PaletteProvider {
    public let id = "shortcuts"
    public let registry: ActionRegistry

    public init(registry: ActionRegistry) {
        self.registry = registry
    }

    public var immediateItems: [PaletteItem]? { makeItems() }
    public func items() async -> [PaletteItem] { makeItems() }

    public func makeItems() -> [PaletteItem] {
        registry.entries.compactMap { entry -> PaletteItem? in
            let id = entry.descriptor.id
            guard let keycaps = registry.shortcutKeycaps(for: id) else { return nil }
            var keywords = entry.descriptor.keywords + [id.rawValue]
            if let shortcut = registry.effectiveShortcut(for: id) { keywords += shortcut.searchTokens }
            keywords.append(keycaps.joined())
            let registry = registry
            return PaletteItem(
                id: "shortcut:\(id.rawValue)",
                title: entry.descriptor.title,
                subtitle: entry.descriptor.category.title,
                symbol: entry.descriptor.symbol,
                keycaps: keycaps,
                section: RegistryPaletteProvider.section(for: entry.descriptor.category),
                keywords: keywords,
                isEnabled: registry.canPerform(id),
                primary: PaletteCommand(id: "run", title: PaletteStrings.runCommand, symbol: "return", effect: .perform { registry.perform(id) }),
                secondary: [
                    PaletteCommand(id: "copyID", title: PaletteStrings.copyActionID, symbol: "doc.on.doc", effect: .perform { PaletteClipboard.copy(id.rawValue) }),
                    PaletteCommand(id: "copyShortcut", title: PaletteStrings.copyShortcut, symbol: "keyboard", effect: .perform { PaletteClipboard.copy(keycaps.joined()) }),
                ],
                frecencyKey: "action:\(id.rawValue)"
            )
        }
    }
}
