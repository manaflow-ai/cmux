/// App-resolved, localized chrome strings the "Show more" session popover renders.
///
/// `String(localized:)` must resolve against the host app bundle (this package's
/// `Bundle.module` lacks the session-index keys), so the app constructs this struct
/// with already-resolved values and hands it to ``SectionPopoverView``. Without it the
/// in-package strings would silently fall back to their English defaults and drop the
/// Japanese (and any future) translations.
public struct SectionPopoverStrings: Sendable {
    /// Placeholder shown in the search field ("Search Vault").
    public let searchPlaceholder: String
    /// Empty-result text ("No matches").
    public let noMatches: String
    /// End-of-list sentinel text ("You've reached the end").
    public let endOfList: String
    /// Loading-row status text ("Loading…").
    public let loading: String

    /// Creates the app-resolved chrome strings for the "Show more" popover.
    public init(
        searchPlaceholder: String,
        noMatches: String,
        endOfList: String,
        loading: String
    ) {
        self.searchPlaceholder = searchPlaceholder
        self.noMatches = noMatches
        self.endOfList = endOfList
        self.loading = loading
    }
}
