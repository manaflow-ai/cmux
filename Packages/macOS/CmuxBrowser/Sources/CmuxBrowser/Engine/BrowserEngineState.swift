public import Foundation

/// Engine-neutral browser state projected into browser chrome and persistence.
public struct BrowserEngineState: Equatable, Sendable {
    /// The current top-level URL.
    public var url: URL?

    /// The current document title.
    public var title: String

    /// Whether a top-level navigation is in progress.
    public var isLoading: Bool

    /// Whether the engine can traverse backward in native history.
    public var canGoBack: Bool

    /// Whether the engine can traverse forward in native history.
    public var canGoForward: Bool

    /// A monotonic revision advanced after each completed top-level navigation.
    public var navigationCompletionRevision: UInt64

    /// A visible engine-startup or transport error, when present.
    public var errorMessage: String?

    /// Creates an engine state snapshot.
    ///
    /// - Parameters:
    ///   - url: The current top-level URL.
    ///   - title: The current document title.
    ///   - isLoading: Whether a top-level navigation is active.
    ///   - canGoBack: Whether native backward history is available.
    ///   - canGoForward: Whether native forward history is available.
    ///   - navigationCompletionRevision: The number of completed top-level navigations.
    ///   - errorMessage: A user-facing engine error, if present.
    public init(
        url: URL? = nil,
        title: String = "",
        isLoading: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        navigationCompletionRevision: UInt64 = 0,
        errorMessage: String? = nil
    ) {
        self.url = url
        self.title = title
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.navigationCompletionRevision = navigationCompletionRevision
        self.errorMessage = errorMessage
    }
}
