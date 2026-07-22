/// One statically declared argument accepted by a command-palette action.
public struct ControlCommandPaletteArgument: Sendable, Equatable {
    /// One finite argument value exposed to control-socket clients.
    public struct Choice: Sendable, Equatable {
        /// Stable value accepted by `palette.run`.
        public let value: String
        /// Localized label shown by interactive clients.
        public let title: String

        /// Creates one finite command-palette argument choice.
        public init(value: String, title: String) {
            self.value = value
            self.title = title
        }
    }

    /// Stable argument name used on the wire.
    public let name: String
    /// Localized argument label shown by interactive clients.
    public let title: String
    /// Wire value type, currently `string`, `path`, or `boolean`.
    public let type: String
    /// Whether automation callers must supply the argument.
    public let required: Bool
    /// Whether an explicitly supplied empty string is valid.
    public let allowsEmpty: Bool
    /// Finite accepted values, or an empty array for a free-form argument.
    public let choices: [Choice]

    /// Creates an action argument description.
    public init(
        name: String,
        title: String? = nil,
        type: String,
        required: Bool,
        allowsEmpty: Bool,
        choices: [Choice] = []
    ) {
        self.name = name
        self.title = title ?? name
        self.type = type
        self.required = required
        self.allowsEmpty = allowsEmpty
        self.choices = choices
    }
}

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
