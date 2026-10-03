public import Foundation

/// The ids of the built-in palette scopes (plans/cmux-next/palette-scopes.md
/// section 3.5).
nonisolated extension PaletteScopeID {
    public static let commands: PaletteScopeID = "commands"
    public static let tabs: PaletteScopeID = "tabs"
    public static let workspaces: PaletteScopeID = "workspaces"
    public static let settings: PaletteScopeID = "settings"
    public static let shortcuts: PaletteScopeID = "shortcuts"
    public static let scopes: PaletteScopeID = "scopes"
}

/// The built-in scopes and the root, as descriptors.
nonisolated extension PaletteScopeDescriptor {
    /// The root: the full palette.
    public static var paletteRoot: PaletteScopeDescriptor {
        PaletteScopeDescriptor(id: .root, title: PaletteStrings.commandsTitle, symbol: "command",
                               placeholder: PaletteStrings.searchPlaceholder, openAction: "commandPalette")
    }

    /// Built-in scopes whose sources exist. English keywords always work;
    /// the localized title also works as a keyword.
    public static func builtIns(tabs: Bool, workspaces: Bool, settings: Bool) -> [PaletteScopeDescriptor] {
        var scopes: [PaletteScopeDescriptor] = []
        if tabs {
            scopes.append(scope(PaletteScopeID.tabs, PaletteStrings.sectionTabs, "rectangle.on.rectangle", PaletteStrings.tabSearchPlaceholder,
                                prefix: "@", keywords: ["tabs", "tab"], openAction: "tab.search", emptyQuerySelection: 1))
        }
        if workspaces {
            scopes.append(scope(PaletteScopeID.workspaces, PaletteStrings.sectionWorkspaces, "rectangle.stack", PaletteStrings.workspacesPlaceholder,
                                prefix: "#", keywords: ["workspaces", "workspace"], openAction: "goToWorkspace"))
        }
        scopes.append(scope(PaletteScopeID.commands, PaletteStrings.commandsTitle, "command", PaletteStrings.searchPlaceholder,
                            prefix: ">", keywords: ["commands", "actions"]))
        if settings {
            scopes.append(scope(PaletteScopeID.settings, PaletteStrings.sectionSettings, "switch.2", PaletteStrings.settingsPlaceholder,
                                prefix: ",", keywords: ["settings", "preferences"], openAction: "palette.toggleSetting"))
        }
        scopes.append(scope(PaletteScopeID.shortcuts, PaletteStrings.shortcutsTitle, "keyboard", PaletteStrings.shortcutsPlaceholder,
                            keywords: ["shortcuts", "keys"], openAction: "palette.searchShortcuts"))
        scopes.append(scope(PaletteScopeID.scopes, PaletteStrings.scopesTitle, "square.grid.2x2", PaletteStrings.scopesPlaceholder, prefix: "?"))
        scopes.append(PaletteScopeDescriptor(id: .actionsScope, title: PaletteStrings.actions, symbol: "filemenu.and.selection",
                                             placeholder: PaletteStrings.searchActionsPlaceholder, parents: .only([])))
        return scopes
    }

    private static func scope(_ id: PaletteScopeID, _ title: String, _ symbol: String, _ placeholder: String, prefix: String? = nil,
                              keywords: [String] = [], openAction: String? = nil, emptyQuerySelection: Int = 0) -> PaletteScopeDescriptor {
        var words = keywords
        let localized = title.lowercased()
        if !words.contains(localized), !localized.contains(" ") { words.append(localized) }
        return PaletteScopeDescriptor(id: id, title: title, symbol: symbol, placeholder: placeholder, prefix: prefix, keywords: words,
                                      emptyQuerySelection: emptyQuerySelection, openAction: openAction)
    }
}

/// Rows for scopes: the `?` scope lists every scope, and the root lists
/// them as a Search In section (scope entry prototype).
final class PaletteScopeListProvider: PaletteProvider {
    let id = "scopes"
    let showsItemsForEmptyQuery: Bool
    private let graph: PaletteScopeGraph
    private let config: PaletteNavConfig
    private let from: PaletteScopeID

    init(graph: PaletteScopeGraph, config: PaletteNavConfig, from: PaletteScopeID, showsItemsForEmptyQuery: Bool) {
        self.graph = graph
        self.config = config
        self.from = from
        self.showsItemsForEmptyQuery = showsItemsForEmptyQuery
    }

    var immediateItems: [PaletteItem]? { makeItems() }
    func items() async -> [PaletteItem] { makeItems() }

    private func makeItems() -> [PaletteItem] {
        let section = PaletteSection(id: "scopes", title: PaletteStrings.sectionScopes, order: -200)
        return graph.order.compactMap { graph.scopes[$0] }
            .filter { $0.id != from && $0.id != PaletteScopeID.scopes && $0.parents != .only([]) }
            .map { scope in
                var item = PaletteItem(
                    id: "scope:\(scope.id.rawValue)", title: scope.title, subtitle: hint(for: scope), symbol: scope.symbol,
                    keycaps: config.prefixEntry ? scope.prefix.map { [$0] } : nil, section: section, keywords: scope.keywords,
                    primary: PaletteCommand(id: "enter", title: PaletteStrings.open, symbol: "arrow.right", effect: .performKeepingOpen {}),
                    frecencyKey: "scope:\(scope.id.rawValue)")
                item.enters = scope.id
                return item
            }
    }

    private func hint(for scope: PaletteScopeDescriptor) -> String? {
        let prefix = config.prefixEntry ? scope.prefix : nil
        let keyword = config.keywordEntry ? scope.keywords.first : nil
        switch (prefix, keyword) {
        case let (prefix?, keyword?): return PaletteStrings.scopeHintPrefixKeyword(prefix, keyword)
        case let (prefix?, nil): return PaletteStrings.scopeHintPrefix(prefix)
        case let (nil, keyword?): return PaletteStrings.scopeHintKeyword(keyword)
        case (nil, nil): return nil
        }
    }
}

/// The `actions` scope of a row: its commands as rows. Each runs exactly
/// what the row's Actions menu entry runs.
enum PaletteItemActionsPage {
    @MainActor
    static func make(for item: PaletteItem, model: PaletteModel) -> PalettePageSpec {
        let rows = item.allCommands.map { command in
            PaletteItem(id: "action:\(command.id)", title: command.title, symbol: command.symbol, primary: command, frecencyKey: nil)
        }
        return PalettePageSpec(
            id: "actions:\(item.id)", title: item.title, placeholder: PaletteStrings.searchActionsPlaceholder,
            symbol: "filemenu.and.selection", providers: [StaticPaletteProvider(id: "actions", items: rows)], scope: .actionsScope)
    }
}
