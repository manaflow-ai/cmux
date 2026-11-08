/// Resolves host-specific shortcut defaults without shared mutable state.
///
/// The settings package owns the built-in table, but a host may have a more
/// specific default. For example, cmux assigns right-sidebar digit shortcuts
/// from the visible tab order. The host constructs one resolver at its
/// composition root and passes it to the settings owner that needs it. A
/// resolver is a value, so previews and multiple hosts can use different
/// defaults in the same process without affecting one another.
public struct ShortcutDefaultResolver: Sendable {
    /// The result of resolving one action's host default.
    public enum Result: Sendable {
        /// Use the package's built-in default.
        case useBuiltIn
        /// Use `stroke`; `nil` explicitly means the action is unbound.
        case stroke(ShortcutStroke?)
    }

    /// A host callback that computes a default from current host state.
    public typealias Provider = @Sendable (ShortcutAction) -> Result

    private let provider: Provider

    /// Creates a resolver backed by `provider`.
    public init(provider: @escaping Provider) {
        self.provider = provider
    }

    /// A resolver that always uses the package's built-in defaults.
    public static let builtIn = Self(provider: { _ in .useBuiltIn })

    /// Resolves `action`, falling back to ``Result/useBuiltIn`` when the host
    /// provider has no override.
    func result(for action: ShortcutAction) -> Result {
        provider(action)
    }
}
