/// One action exposed by the live command palette.
public struct ControlCommandPaletteItem: Sendable, Equatable {
    /// The stable action identifier accepted by `palette.run`.
    public let id: String
    /// The localized title shown by Cmd+Shift+P.
    public let title: String
    /// The localized context subtitle shown by Cmd+Shift+P.
    public let subtitle: String
    /// The configured or built-in keyboard shortcut hint, if any.
    public let shortcutHint: String?
    /// Additional search terms registered for the action.
    public let keywords: [String]
    /// Whether the visible palette dismisses after running the action.
    public let dismissOnRun: Bool
    /// Static arguments accepted by this action.
    public let arguments: [ControlCommandPaletteArgument]

    /// Creates a command-palette action description.
    public init(
        id: String,
        title: String,
        subtitle: String,
        shortcutHint: String?,
        keywords: [String],
        dismissOnRun: Bool,
        arguments: [ControlCommandPaletteArgument] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.shortcutHint = shortcutHint
        self.keywords = keywords
        self.dismissOnRun = dismissOnRun
        self.arguments = arguments
    }
}
