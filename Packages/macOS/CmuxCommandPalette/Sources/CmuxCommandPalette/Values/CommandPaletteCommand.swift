import Foundation

/// One runnable palette command: identity, display strings, search keywords,
/// and the action executed when the command is activated.
public struct CommandPaletteCommand: Identifiable {
    /// Stable command identifier.
    public let id: String
    /// Tie-break rank; lower sorts first at equal score.
    public let rank: Int
    /// Display title.
    public let title: String
    /// Display subtitle.
    public let subtitle: String
    /// Optional keyboard-shortcut hint shown trailing the row.
    public let shortcutHint: String?
    /// Optional kind label (for example a switcher row's surface kind).
    public let kindLabel: String?
    /// Additional search keywords.
    public let keywords: [String]
    /// Whether activating the command dismisses the palette.
    public let dismissOnRun: Bool
    /// Finite-choice values collected interactively before running.
    public let choiceArguments: [CommandPaletteChoiceArgument]
    /// The action executed on activation.
    public let action: () -> Void
    private let argumentAction: ([String: String]) -> Void

    /// Creates a command that does not consume finite-choice values.
    /// - Parameters:
    ///   - id: Stable command identifier.
    ///   - rank: Tie-break rank used when search scores match.
    ///   - title: Display title.
    ///   - subtitle: Display subtitle.
    ///   - shortcutHint: Optional trailing keyboard-shortcut hint.
    ///   - kindLabel: Optional trailing kind label.
    ///   - keywords: Additional search keywords.
    ///   - dismissOnRun: Whether activation dismisses the palette.
    ///   - choiceArguments: Ordered finite choices presented before the action runs.
    ///   - action: Action executed after argument collection, ignoring collected values.
    public init(
        id: String,
        rank: Int,
        title: String,
        subtitle: String,
        shortcutHint: String?,
        kindLabel: String?,
        keywords: [String],
        dismissOnRun: Bool,
        choiceArguments: [CommandPaletteChoiceArgument] = [],
        action: @escaping () -> Void
    ) {
        self.id = id
        self.rank = rank
        self.title = title
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.kindLabel = kindLabel
        self.keywords = keywords
        self.dismissOnRun = dismissOnRun
        self.choiceArguments = choiceArguments
        self.action = action
        argumentAction = { _ in action() }
    }

    /// Creates a command whose action consumes collected argument values.
    /// - Parameters:
    ///   - id: Stable command identifier.
    ///   - rank: Tie-break rank used when search scores match.
    ///   - title: Display title.
    ///   - subtitle: Display subtitle.
    ///   - shortcutHint: Optional trailing keyboard-shortcut hint.
    ///   - kindLabel: Optional trailing kind label.
    ///   - keywords: Additional search keywords.
    ///   - dismissOnRun: Whether activation dismisses the palette.
    ///   - choiceArguments: Ordered finite-choice values collected before execution.
    ///   - argumentAction: Action receiving collected values keyed by argument name.
    public init(
        id: String,
        rank: Int,
        title: String,
        subtitle: String,
        shortcutHint: String?,
        kindLabel: String?,
        keywords: [String],
        dismissOnRun: Bool,
        choiceArguments: [CommandPaletteChoiceArgument],
        argumentAction: @escaping ([String: String]) -> Void
    ) {
        self.id = id
        self.rank = rank
        self.title = title
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.kindLabel = kindLabel
        self.keywords = keywords
        self.dismissOnRun = dismissOnRun
        self.choiceArguments = choiceArguments
        action = { argumentAction([:]) }
        self.argumentAction = argumentAction
    }

    /// Runs the command with values collected by the palette.
    /// - Parameter arguments: Collected values keyed by declared argument name.
    public func run(arguments: [String: String] = [:]) {
        argumentAction(arguments)
    }

    /// Texts the search corpus indexes for this command.
    public var searchableTexts: [String] {
        [title, subtitle] + keywords
    }
}
