/// Main-actor action closures the browser-data import-hint buttons invoke.
///
/// Each closure runs the app-side mutation (present the import dialog from the
/// hint, open the browser-import settings, dismiss the hint). Keeping the side
/// effects behind closures lets the import-hint and empty-state views live in
/// this package while every panel mutation and `@State` presentation flag stays
/// on the app-side forwarder that builds these values.
public struct BrowserImportHintActions {
    /// Present the import dialog from the hint's primary button.
    public var onPresentImportFromHint: @MainActor () -> Void
    /// Open the browser-import section of Settings.
    public var onOpenImportSettings: @MainActor () -> Void
    /// Dismiss the import hint (hide it on blank tabs).
    public var onDismissImportHint: @MainActor () -> Void

    /// Creates the import-hint action bundle.
    public init(
        onPresentImportFromHint: @escaping @MainActor () -> Void,
        onOpenImportSettings: @escaping @MainActor () -> Void,
        onDismissImportHint: @escaping @MainActor () -> Void
    ) {
        self.onPresentImportFromHint = onPresentImportFromHint
        self.onOpenImportSettings = onOpenImportSettings
        self.onDismissImportHint = onDismissImportHint
    }
}
