public import CmuxNextActions
public import CmuxNextDesign
public import CoreGraphics
import CmuxAgentBrands
import Foundation

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
    /// A page's favicon (Search Tabs' browser rows), drawn as is in the symbol's place.
    public var image: CGImage?
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
    /// A font family the title draws in (a font setting's values show each
    /// font in its own face). Nil, or a family not installed, draws the body font.
    public var fontFamily: String?
    /// A group color drawn as a ball in the icon's place, resolved by the row in its window's
    /// theme scope (a room's theme) and again on a theme change (cx-wqn5).
    public var ball: PaletteBall?
    /// The row matches only a query that starts with this text, and never
    /// shows for an empty query (the picker's hidden files: `.`).
    public var queryPrefix: String?
    /// The row shows for an empty query only, never as a match (the
    /// picker's Locations).
    public var hidesWhenTyping = false
    /// The row matches a query but is left out of the empty query's list (a family member that
    /// its family's row stands for).
    public var hidesWhenQueryEmpty = false
    /// A row of a secondary kind (a setting): it ranks below a command with
    /// the same match (ten setting rows are titled "Color"), so 200 setting
    /// rows never bury the commands.
    public var isDemoted = false
    /// The catalog's first-use suggestion order: the row shows in the empty
    /// query's Suggested section (`ActionDescriptor.paletteSuggestionRank`).
    public var suggestedRank: Int?
    /// Short ids the row is known by, such as a Chief subagent workspace's `a612`: a query that is
    /// one of them, or its digits (`612`), puts the row first, above every text match. Not keywords,
    /// so a handle's letters never match other rows' words.
    public var handles: [String] = []
    /// Phrases that name the row (the catalog's built-in aliases, `ActionDescriptor.paletteAliases`):
    /// the ranker ranks the row for a query that is one of them as it ranks a `palette.aliases` match.
    public var aliases: [String] = []
    /// Scalar offsets into `subtitle` drawn emphasized: the words a row was found by when the subtitle
    /// is a snippet of what matched (the chats page's match in what was said). Empty draws it plain.
    public var subtitleHighlights: [Int] = []
    /// Whether an on/off command is on now, read when the palette opened; nil for any other row.
    /// The row shows it as ``PaletteTunables/toggleStyle`` says.
    public var toggleState: Bool?
    /// Reads ``toggleState`` now. A page that lists rows built earlier (a family page such as Pane
    /// Borders and Focus Ring…) shows each one's state as it is when the page loads, so a row flipped
    /// in place reads its new state there too (``StaticPaletteProvider``), with the title and icon
    /// ``PaletteToggleStyle`` gives that state (``toggleBase``).
    public var readsToggleState: (@MainActor () -> Bool)?
    /// The title and icon of a row with ``readsToggleState`` before its style adds the state.
    public var toggleBase: (title: String, symbol: String?)?
    /// The facts the preview pane lists for this row (`experiments.palettePreview`): read only for the row the pane
    /// shows, when it shows it, never for every row. Nil: the pane lists what the row itself says (``PaletteFacts/of(_:)``).
    public var facts: (@MainActor () -> [PaletteFact])?

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

/// One line of the preview pane's Information list: a label and its value.
public nonisolated struct PaletteFact: Equatable, Sendable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// The facts the preview pane lists for a row (`experiments.palettePreview`), from what the app already has for it: a
/// workspace's folder, tab and agent counts, a tab's kind, place and agent, a command's shortcut and category. Built
/// for the one row the pane shows, when it shows it.
enum PaletteFacts {
    /// The row's facts: its own (``PaletteItem/facts``), else what its title, kind, subtitle and keys say.
    static func of(_ item: PaletteItem) -> [PaletteFact] {
        if let facts = item.facts { return facts() }
        return list([
            (PaletteStrings.factKind, item.accessory),
            (PaletteStrings.factDetails, item.subtitle),
            (PaletteStrings.factShortcut, item.keycaps?.joined()),
            (PaletteStrings.factCategory, item.section.title),
        ])
    }

    /// A Go to Workspace row's facts.
    static func workspace(_ workspace: PaletteWorkspace, now: Date) -> [PaletteFact] {
        list([
            (PaletteStrings.factName, workspace.title),
            (PaletteStrings.factDirectory, workspace.directory.map(abbreviatePath)),
            (PaletteStrings.factTabs, workspace.tabCount.map { String($0) }),
            (PaletteStrings.factAgents, workspace.agentCount.flatMap { $0 > 0 ? String($0) : nil }),
            (PaletteStrings.factBranch, workspace.branch),
            (PaletteStrings.factGroup, workspace.groupName),
            (PaletteStrings.factMachine, workspace.machineName),
            (PaletteStrings.factStatus, workspace.isSelected ? PaletteStrings.current
                : (workspace.unreadCount > 0 ? PaletteStrings.unreadCount(workspace.unreadCount) : nil)),
            (PaletteStrings.factLastActive, workspace.lastUsed.map { relative($0, now: now) }),
        ])
    }

    /// A group, pane or tab row's facts (terminal, agent chat, browser and the other tab kinds).
    static func navigation(_ entry: PaletteNavigationEntry, now: Date) -> [PaletteFact] {
        let kind: String = switch entry.kind {
        case .group: PaletteStrings.kindGroup
        case .pane: PaletteStrings.kindPane
        case .tab(let tab): NavigationPaletteProvider.kindLabel(tab)
        }
        var workspaces: String?
        if case .group(let count) = entry.kind { workspaces = String(count) }
        return list([
            (PaletteStrings.factTitle, entry.title),
            (PaletteStrings.factKind, kind),
            (PaletteStrings.sectionWorkspaces, workspaces),
            (PaletteStrings.factWorkspace, entry.workspaceTitle),
            (PaletteStrings.factGroup, entry.groupTitle),
            (PaletteStrings.factDirectory, entry.cwd.map(abbreviatePath)),
            (PaletteStrings.factAddress, entry.url),
            (PaletteStrings.factAgent, entry.agent.map { AgentBrandCatalog.spec(forAgent: $0)?.name ?? $0 }),
            (PaletteStrings.factSession, entry.sessionID),
            (PaletteStrings.factStatus, entry.isCurrent ? PaletteStrings.current : nil),
            (PaletteStrings.factLastActive, entry.lastUsed.map { relative($0, now: now) }),
        ])
    }

    /// A Go to Tab row's facts.
    static func tab(_ tab: PaletteTab) -> [PaletteFact] {
        let kind: String = switch tab.kind {
        case .terminal: PaletteStrings.kindTerminal
        case .browser: PaletteStrings.kindBrowser
        case .other: PaletteStrings.kindTab
        }
        return list([
            (PaletteStrings.factTitle, tab.title),
            (PaletteStrings.factKind, kind),
            (PaletteStrings.factWorkspace, tab.workspaceTitle),
            (PaletteStrings.factStatus, tab.isSelected ? PaletteStrings.current : nil),
        ])
    }

    /// A command row's facts: its name, shortcut, category and what it does.
    static func command(name: String, keycaps: [String]?, category: String?, description: String?) -> [PaletteFact] {
        list([
            (PaletteStrings.factCommand, name),
            (PaletteStrings.factShortcut, keycaps?.joined()),
            (PaletteStrings.factCategory, category),
            (PaletteStrings.factDescription, description),
        ])
    }

    /// The pairs with a value, in order.
    private static func list(_ pairs: [(String, String?)]) -> [PaletteFact] {
        pairs.compactMap { label, value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return PaletteFact(label, value)
        }
    }

    /// "5 min. ago", "yesterday": how long ago `date` was.
    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}
