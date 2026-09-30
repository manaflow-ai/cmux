import Foundation

/// One palette command as an agent sees it over the control socket.
///
/// The palette's own row type (``CommandPaletteCommand``) carries a
/// `() -> Void` action and is therefore neither `Sendable` nor meaningful off
/// the main actor. This is the flat, sendable projection: what the command is
/// called, and whether it can be used right now.
public struct CommandPaletteAgentCommand: Sendable, Equatable, Identifiable {
    /// Stable command identifier, the same string the palette uses.
    public let commandId: String
    /// Display title, after any config override the palette would apply.
    public let title: String
    /// Display subtitle.
    public let subtitle: String
    /// Keyboard-shortcut hint, when the command has a binding.
    public let shortcutHint: String?
    /// Whether the command's `enablement` predicate holds in this context.
    ///
    /// A listed command with `isEnabled == false` exists here but cannot be
    /// used yet, which is a different answer from being absent.
    public let isEnabled: Bool

    public var id: String { commandId }

    public init(
        commandId: String,
        title: String,
        subtitle: String,
        shortcutHint: String?,
        isEnabled: Bool
    ) {
        self.commandId = commandId
        self.title = title
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.isEnabled = isEnabled
    }
}
