public import CmuxNextActions

/// One Commands-palette (Cmd-Shift-P) action row as another surface lists it.
///
/// ``PaletteController/commandEntries()`` builds these from the same registry rows the
/// palette shows, so a surface such as the New Tab page's dropdown lists exactly the
/// palette's actions and never keeps a second list that drifts from it.
public struct PaletteCommandEntry: Sendable, Equatable {
    /// The registry action the row runs.
    public var id: ActionID
    /// The row's title, as the palette shows it (a toggle reads as the change it makes).
    public var title: String
    /// The section title the palette groups the row under ("Tabs", "Workspaces").
    public var section: String
    /// Extra words that match the row (aliases, the action ID).
    public var keywords: [String]
    /// The action's shortcut keycaps, one entry per key; empty without a shortcut.
    public var keycaps: [String]
    /// The row's SF Symbol name, if any.
    public var symbol: String?

    /// Creates an entry.
    /// - Parameters:
    ///   - id: The registry action the row runs.
    ///   - title: The row's title.
    ///   - section: The section title the palette groups the row under.
    ///   - keywords: Extra words that match the row.
    ///   - keycaps: The shortcut keycaps; empty without a shortcut.
    ///   - symbol: The row's SF Symbol name.
    public init(id: ActionID, title: String, section: String, keywords: [String] = [], keycaps: [String] = [],
                symbol: String? = nil) {
        self.id = id
        self.title = title
        self.section = section
        self.keywords = keywords
        self.keycaps = keycaps
        self.symbol = symbol
    }
}
