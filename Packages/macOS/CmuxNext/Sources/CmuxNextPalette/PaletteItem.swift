public import CmuxNextActions

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
    /// Key for usage tracking; defaults to `id`. Nil disables tracking.
    public var frecencyKey: String?
    /// Score adjustment applied after matching; positive ranks higher.
    public var rankBias: Int
    /// The registry action this row runs, if any: Cmd-K edits its shortcut.
    public var actionID: ActionID?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        accessory: String? = nil,
        symbol: String? = nil,
        keycaps: [String]? = nil,
        section: PaletteSection = .results,
        keywords: [String] = [],
        isEnabled: Bool = true,
        primary: PaletteCommand,
        alternate: PaletteCommand? = nil,
        secondary: [PaletteCommand] = [],
        frecencyKey: String? = nil,
        rankBias: Int = 0,
        actionID: ActionID? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.symbol = symbol
        self.keycaps = keycaps
        self.section = section
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.primary = primary
        self.alternate = alternate
        self.secondary = secondary
        self.frecencyKey = frecencyKey ?? id
        self.rankBias = rankBias
        self.actionID = actionID
    }

    /// Every command, primary first, as the Actions menu lists them.
    public var allCommands: [PaletteCommand] {
        var commands = [primary]
        if let alternate { commands.append(alternate) }
        commands += secondary
        return commands
    }
}
