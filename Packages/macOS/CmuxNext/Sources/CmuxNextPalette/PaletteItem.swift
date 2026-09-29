public import Foundation

/// A titled group of rows. Sections sort by `order` when the query is empty
/// and by their best match otherwise.
public struct PaletteSection: Hashable, Sendable {
    public let id: String
    public let title: String
    public let order: Int

    public init(id: String, title: String, order: Int) {
        self.id = id
        self.title = title
        self.order = order
    }

    /// Recently and frequently used items, shown first for an empty query.
    public static var recent: PaletteSection {
        PaletteSection(id: "recent", title: PaletteStrings.sectionRecent, order: -100)
    }

    /// Unsectioned results, such as the submit row of a text entry page.
    public static var results: PaletteSection {
        PaletteSection(id: "results", title: "", order: 0)
    }
}

/// What happens when a command runs.
public enum PaletteEffect {
    /// Close the palette, then run.
    case perform(@MainActor () -> Void)
    /// Run and keep the palette open (toggles); the page reloads its items.
    case performKeepingOpen(@MainActor () -> Void)
    /// Open a nested list inside the palette.
    case push(PalettePageSpec)
    /// Replace the list with inline text entry ("Rename Tab…").
    case textInput(PaletteTextInputSpec)
}

/// One invocable command on an item. The first command is the primary
/// action (Return); the rest appear in the Actions menu (Cmd-K).
public struct PaletteCommand: Identifiable {
    public let id: String
    public var title: String
    public var symbol: String?
    public var isDestructive: Bool
    public var effect: PaletteEffect

    public init(id: String, title: String, symbol: String? = nil, isDestructive: Bool = false, effect: PaletteEffect) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.isDestructive = isDestructive
        self.effect = effect
    }
}

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
        rankBias: Int = 0
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
    }

    /// Every command, primary first, as the Actions menu lists them.
    public var allCommands: [PaletteCommand] {
        var commands = [primary]
        if let alternate { commands.append(alternate) }
        commands += secondary
        return commands
    }
}

/// A list page: the root command list or a nested list.
public struct PalettePageSpec {
    public let id: String
    public var title: String
    public var placeholder: String
    public var symbol: String
    public var providers: [any PaletteProvider]
    /// Show a Recent section for an empty query.
    public var showsRecent: Bool

    public init(
        id: String,
        title: String,
        placeholder: String,
        symbol: String = "command",
        providers: [any PaletteProvider],
        showsRecent: Bool = false
    ) {
        self.id = id
        self.title = title
        self.placeholder = placeholder
        self.symbol = symbol
        self.providers = providers
        self.showsRecent = showsRecent
    }
}

/// An inline text entry page, used by argument-taking actions.
public struct PaletteTextInputSpec {
    public let id: String
    public var title: String
    public var placeholder: String
    public var symbol: String
    public var initialText: String
    /// Row title for the current text, such as "Rename to “api”".
    public var submitTitle: @MainActor (String) -> String
    public var isValid: @MainActor (String) -> Bool
    public var submit: @MainActor (String) -> Void

    public init(
        id: String,
        title: String,
        placeholder: String,
        symbol: String = "pencil",
        initialText: String = "",
        submitTitle: @escaping @MainActor (String) -> String,
        isValid: @escaping @MainActor (String) -> Bool = { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
        submit: @escaping @MainActor (String) -> Void
    ) {
        self.id = id
        self.title = title
        self.placeholder = placeholder
        self.symbol = symbol
        self.initialText = initialText
        self.submitTitle = submitTitle
        self.isValid = isValid
        self.submit = submit
    }
}
