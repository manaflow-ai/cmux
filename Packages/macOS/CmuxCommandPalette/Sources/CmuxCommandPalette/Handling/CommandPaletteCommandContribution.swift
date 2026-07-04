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
    /// Optional trailing "kind" badge (e.g. a custom command's folder
    /// breadcrumb). Only shown when there is no `shortcutHint`.
    public let kindLabel: String?
    /// Additional search keywords.
    public let keywords: [String]
    /// Whether activating the command dismisses the palette.
    public let dismissOnRun: Bool
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
        kindLabel: String? = nil,
        keywords: [String] = [],
        dismissOnRun: Bool = true,
        when: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true },
        enablement: @escaping (CommandPaletteContextSnapshot) -> Bool = { _ in true }
    ) {
        self.commandId = commandId
        self.title = title
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.kindLabel = kindLabel
        self.keywords = keywords
        self.dismissOnRun = dismissOnRun
        self.when = when
        self.enablement = enablement
    }
}
