public import CmuxNextActions
public import CmuxNextDesign

/// One row of palette results.
public struct PaletteItem: Identifiable {
    public let id: String
    public var title: String
    /// Secondary text shown after the title in gray.
    public var subtitle: String?
    /// Right-aligned text before the shortcut (a type, state, or count).
    public var accessory: String?
    /// SF Symbol name.
    public var symbol: String?
    /// An agent brand id (CmuxAgentBrands, such as "claude"): the row draws that brand's
    /// mark in the symbol's place, tinted like the symbol. Nil, or a brand without a mark,
    /// draws `symbol`.
    public var brand: String?
    /// Shortcut keycaps shown at the right edge, one badge per entry.
    public var keycaps: [String]?
    public var section: PaletteSection
    /// Extra words that match this item (aliases, the action ID, shortcut words).
    public var keywords: [String]
    /// Disabled items stay visible but dimmed and do not run.
    public var isEnabled: Bool
    public var primary: PaletteCommand
    /// Runs on Cmd-Return. Nil falls back to `primary`.
    public var alternate: PaletteCommand?
    /// Further commands for the Actions menu.
    public var secondary: [PaletteCommand]
    /// Runs on Cmd-W and keeps the palette open: closes the row's object
    /// (Search Tabs closes the tab, or forgets a closed one). The row
    /// leaves the list and the next row is selected. Also listed in the
    /// Actions menu.
    public var closeCommand: PaletteCommand?
    /// Key for usage tracking; defaults to `id`. Nil disables tracking.
    public var frecencyKey: String?
    /// Score adjustment applied after matching; positive ranks higher.
    public var rankBias: Int
    /// The registry action this row runs, if any: Cmd-K edits its shortcut.
    public var actionID: ActionID?
    /// A scope row: Return, Tab or a click enters this scope.
    public var enters: PaletteScopeID?
    /// Tab drills into this scope with the row as its context (a
    /// workspace's tabs). Nil uses the item-actions prototype setting.
    public var drills: PaletteScopeID?
    /// The row's typed commands, primary first (`palette.run`). Empty for a
    /// row that only the palette UI can run.
    public var actionRefs: [PaletteActionRef] = []
    /// Real colors drawn in the icon's place (a color setting's value, a
    /// theme's colors; R98). Empty draws `symbol`.
    public var swatches: [ThemeRGB] = []
    /// The row matches only a query that starts with this text, and never
    /// shows for an empty query (the picker's hidden files: `.`).
    public var queryPrefix: String?
    /// The row shows for an empty query only, never as a match (the
    /// picker's Locations).
    public var hidesWhenTyping = false

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        accessory: String? = nil,
        symbol: String? = nil,
        brand: String? = nil,
        keycaps: [String]? = nil,
        section: PaletteSection = .results,
        keywords: [String] = [],
        isEnabled: Bool = true,
        primary: PaletteCommand,
        alternate: PaletteCommand? = nil,
        secondary: [PaletteCommand] = [],
        closeCommand: PaletteCommand? = nil,
        frecencyKey: String? = nil,
        rankBias: Int = 0,
        actionID: ActionID? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.symbol = symbol
        self.brand = brand
        self.keycaps = keycaps
        self.section = section
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.primary = primary
        self.alternate = alternate
        self.secondary = secondary
        self.closeCommand = closeCommand
        self.frecencyKey = frecencyKey ?? id
        self.rankBias = rankBias
        self.actionID = actionID
    }

    /// Every command, primary first, as the Actions menu lists them.
    public var allCommands: [PaletteCommand] {
        var commands = [primary]
        if let alternate { commands.append(alternate) }
        commands += secondary
        if let closeCommand { commands.append(closeCommand) }
        return commands
    }
}
