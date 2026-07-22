/// An immutable snapshot consumed by extension toolbar and manager views.
public struct BrowserWebExtensionsPresentationSnapshot: Equatable, Sendable {
    /// Whether extension presentation data is available.
    public let state: BrowserWebExtensionsPresentationState

    /// Installed extension action values.
    public let extensions: [BrowserWebExtensionPresentationItem]

    /// Sanitized per-extension load failures.
    public let failures: [BrowserWebExtensionPresentationFailure]

    /// The profile-managed extension directory path.
    public let directoryPath: String

    /// Creates an immutable extension presentation snapshot.
    ///
    /// - Parameters:
    ///   - state: Whether presentation data is available.
    ///   - extensions: Installed extension action values.
    ///   - failures: Sanitized per-extension failures.
    ///   - directoryPath: The profile-managed extension directory path.
    public init(
        state: BrowserWebExtensionsPresentationState,
        extensions: [BrowserWebExtensionPresentationItem],
        failures: [BrowserWebExtensionPresentationFailure],
        directoryPath: String
    ) {
        self.state = state
        self.extensions = extensions
        self.failures = failures
        self.directoryPath = directoryPath
    }

    /// A snapshot shown while the profile runtime is loading.
    public static let loading = BrowserWebExtensionsPresentationSnapshot(
        state: .loading,
        extensions: [],
        failures: [],
        directoryPath: ""
    )

    /// A snapshot shown when WebExtensions are unavailable.
    public static let unsupported = BrowserWebExtensionsPresentationSnapshot(
        state: .unsupported,
        extensions: [],
        failures: [],
        directoryPath: ""
    )
}
