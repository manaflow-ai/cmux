/// Resolves the Ghostty action used by native terminal Copy commands.
public nonisolated struct GhosttyCopyActionResolver: Sendable {
    /// Creates a resolver with no mutable state.
    public init() {}

    /// The formats accepted by Ghostty's `copy_to_clipboard` action.
    public nonisolated enum Flavor: String, CaseIterable, Sendable {
        case plain
        case vt
        case html
        case mixed

        /// The canonical Ghostty action spelling for this flavor.
        public var bindingAction: String {
            switch self {
            case .mixed:
                // Keep the parameterless spelling as the default action so
                // native Copy retains Ghostty's version-defined mixed default.
                "copy_to_clipboard"
            case .plain, .vt, .html:
                "copy_to_clipboard:\(rawValue)"
            }
        }
    }

    /// A copy flavor and the trigger Ghostty associates with that action.
    public nonisolated struct Binding: Equatable, Sendable {
        /// The configured clipboard flavor.
        public let flavor: Flavor
        /// The configured trigger for the flavor-specific action.
        public let shortcut: GhosttyTriggerShortcut

        /// Creates a copy-action binding value.
        public init(flavor: Flavor, shortcut: GhosttyTriggerShortcut) {
            self.flavor = flavor
            self.shortcut = shortcut
        }
    }

    /// The action string Ghostty uses when no flavor-specific override is found.
    public static let defaultAction = "copy_to_clipboard"

    /// The standard macOS Copy trigger.
    public static let standardCopyShortcut = GhosttyTriggerShortcut(
        key: "c",
        command: true,
        shift: false,
        option: false,
        control: false
    )

    /// Returns the configured copy action for the native Copy surfaces.
    ///
    /// A unique binding for the standard Command-C trigger wins. Missing or
    /// ambiguous reverse-trigger results retain Ghostty's mixed default.
    public func resolve(bindings: [Binding]) -> String {
        let matchingBindings = bindings.filter {
            $0.shortcut == Self.standardCopyShortcut
        }
        guard matchingBindings.count == 1,
              let binding = matchingBindings.first else {
            return Self.defaultAction
        }
        return binding.flavor.bindingAction
    }
}
