/// Side effects requested by the omnibar reducer for the view layer to perform.
///
/// The reducer is a pure value transform over `OmnibarState`; anything it cannot
/// express as state (selecting field text, blurring to the web view, refreshing
/// or cancelling the debounced suggestion fetch, clearing inline completion) is
/// returned here for the host to carry out.
public struct OmnibarEffects: Equatable, Sendable {
    public var shouldSelectAll: Bool = false
    public var shouldBlurToWebView: Bool = false
    public var shouldRefreshSuggestions: Bool = false
    public var shouldClearInlineCompletion: Bool = false
    public var shouldCancelPendingSuggestionRefresh: Bool = false

    public init() {}
}
