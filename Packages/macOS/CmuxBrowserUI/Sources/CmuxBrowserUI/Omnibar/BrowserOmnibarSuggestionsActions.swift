public import CmuxBrowser

/// Action closures the omnibar-suggestions overlay invokes for a row tap or a
/// pointer-driven highlight.
///
/// `onCommit` runs the app-side commit path for the chosen suggestion (URL
/// navigation, search, tab switch); `onHighlight` updates the panel's omnibar
/// selection. The closures are non-isolated to match the suggestions view's
/// existing parameter shape and the AppKit portal-hosted overlay; the app-side
/// forwarder forms them in its main-actor view context.
public struct BrowserOmnibarSuggestionsActions {
    /// Commit the chosen suggestion (navigate / search / switch tab).
    public var onCommit: (OmnibarSuggestion) -> Void
    /// Highlight the suggestion at the given index (pointer hover / keyboard).
    public var onHighlight: (Int) -> Void

    /// Creates the omnibar-suggestions action bundle.
    public init(
        onCommit: @escaping (OmnibarSuggestion) -> Void,
        onHighlight: @escaping (Int) -> Void
    ) {
        self.onCommit = onCommit
        self.onHighlight = onHighlight
    }
}
