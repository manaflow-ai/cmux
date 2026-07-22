import Foundation

/// Declarative descriptor for one action presented by the command palette:
/// stable identity, static arguments, context-derived display strings, and
/// the `when`/`enablement` gates. The resolved action registry pairs this
/// descriptor with its shared runnable handler.
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
    /// Static argument contract shared by palette and automation adapters.
    public let arguments: [CmuxActionArgumentDefinition]
    /// Whether the command appears at all in this context.
    public let when: (CommandPaletteContextSnapshot) -> Bool
    /// Whether the command is enabled in this context.
    public let enablement: (CommandPaletteContextSnapshot) -> Bool

    /// Creates a contribution; `when` and `enablement` default to always-true.
    public init(
        commandId: String,
        title: @escaping (CommandPaletteContextSnapshot) -> String,
        subtitle: @escaping (CommandPaletteContextSnapshot) -> String,
        shortcutHint: String? = nil,
        keywords: [String] = [],
        dismissOnRun: Bool = true,
        arguments: [CmuxActionArgumentDefinition] = [],
        when: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true },
        enablement: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true }
    ) {
        self.commandId = commandId
        self.title = title
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.keywords = keywords
        self.dismissOnRun = dismissOnRun
        self.arguments = arguments
        self.when = when
        self.enablement = enablement
    }
}
