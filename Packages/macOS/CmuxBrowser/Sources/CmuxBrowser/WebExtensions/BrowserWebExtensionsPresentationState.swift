/// Describes whether extension presentation data is available.
public enum BrowserWebExtensionsPresentationState: Equatable, Sendable {
    /// The operating system does not expose Safari WebExtensions to cmux.
    case unsupported

    /// The profile runtime is still discovering extensions.
    case loading

    /// The snapshot contains the current extension state.
    case ready
}
