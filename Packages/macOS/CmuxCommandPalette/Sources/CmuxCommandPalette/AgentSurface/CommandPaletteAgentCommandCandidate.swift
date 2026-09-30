import Foundation

/// One palette contribution, already evaluated against a context snapshot.
///
/// The evaluation happens where the contributions and the context live (the
/// window's view), and the decision about what an agent may see happens here,
/// in a value type with no view or main-actor dependency. That split is what
/// lets the listing rules be unit tested without a running app.
public struct CommandPaletteAgentCommandCandidate: Sendable, Equatable {
    /// Stable command identifier.
    public let commandId: String
    /// Title the palette would render, config override included.
    public let title: String
    /// Subtitle the palette would render.
    public let subtitle: String
    /// Shortcut hint the palette would render, when there is a binding.
    public let shortcutHint: String?
    /// The contribution's `when` predicate, already applied to the context.
    public let isVisible: Bool
    /// The contribution's `enablement` predicate, already applied.
    public let isEnabled: Bool
    /// Whether the user's config takes this command out of the palette.
    public let isHiddenFromPalette: Bool

    public init(
        commandId: String,
        title: String,
        subtitle: String,
        shortcutHint: String?,
        isVisible: Bool,
        isEnabled: Bool,
        isHiddenFromPalette: Bool
    ) {
        self.commandId = commandId
        self.title = title
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.isVisible = isVisible
        self.isEnabled = isEnabled
        self.isHiddenFromPalette = isHiddenFromPalette
    }
}
