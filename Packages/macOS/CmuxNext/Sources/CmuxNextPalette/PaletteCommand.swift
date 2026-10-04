

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
    /// Show this page in the current one's place, keeping the palette open
    /// (a tree page's step, ``PaletteHierarchy``).
    case replace(PalettePageSpec)
    /// Replace the list with inline text entry ("Rename Tab…").
    case textInput(PaletteTextInputSpec)
    /// Decided when the command runs, not when the row is built: rows are
    /// built for every action on every open, and deciding can be costly
    /// (an argument's target list reads every workspace or tab).
    case deferred(@MainActor () -> PaletteEffect)

    /// The effect to run: a deferred one is decided now.
    public func resolved() -> PaletteEffect {
        var effect = self
        while case .deferred(let decide) = effect { effect = decide() }
        return effect
    }
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
