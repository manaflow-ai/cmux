import Foundation

/// Declarative descriptor for one palette command: identity, context-derived
/// display strings, and the `when`/`enablement` gates. The runnable handler
/// is registered separately through ``CommandPaletteActionHandling``.
public struct CommandPaletteCommandContribution {
    /// Stable command identifier.
    public let commandId: String
    /// Title derived from the context snapshot.
    public let title: (CommandPaletteContextSnapshot) -> String
    /// Subtitle derived from the context snapshot.
    public let subtitle: (CommandPaletteContextSnapshot) -> String
    /// Optional keyboard-shortcut hint.
    public let shortcutHint: String?
    /// Additional search keywords.
    public let keywords: [String]
    /// Whether activating the command dismisses the palette.
    public let dismissOnRun: Bool
    /// Finite-choice values collected interactively before the command runs.
    public let choiceArguments: [CommandPaletteChoiceArgument]
    /// Whether the command appears at all in this context.
    public let when: (CommandPaletteContextSnapshot) -> Bool
    /// Whether the command is enabled in this context.
    public let enablement: (CommandPaletteContextSnapshot) -> Bool

    /// Creates a contribution; `when` and `enablement` default to always-true.
    /// - Parameters:
    ///   - commandId: Stable command identifier.
    ///   - title: Display title derived from the current context.
    ///   - subtitle: Display subtitle derived from the current context.
    ///   - shortcutHint: Optional keyboard-shortcut hint.
    ///   - keywords: Additional search keywords.
    ///   - dismissOnRun: Whether activation dismisses the palette.
    ///   - choiceArguments: Ordered finite choices collected before execution.
    ///   - when: Visibility predicate evaluated against the current context.
    ///   - enablement: Enablement predicate evaluated against the current context.
    public init(
        commandId: String,
        title: @escaping (CommandPaletteContextSnapshot) -> String,
        subtitle: @escaping (CommandPaletteContextSnapshot) -> String,
        shortcutHint: String? = nil,
        keywords: [String] = [],
        dismissOnRun: Bool = true,
        choiceArguments: [CommandPaletteChoiceArgument] = [],
        when: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true },
        enablement: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true }
    ) {
        self.commandId = commandId
        self.title = title
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.keywords = keywords
        self.dismissOnRun = dismissOnRun
        self.choiceArguments = choiceArguments
        self.when = when
        self.enablement = enablement
    }
}
