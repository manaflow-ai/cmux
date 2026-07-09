/// Localized copy for ``ExtensionAccessReviewSheet`` resolved by the app
/// composition root.
///
/// Every string is resolved with `String(localized:)` in the app target so the
/// app bundle's localized catalog (including Japanese) is used; resolving them
/// inside this package bundle would miss the catalog and silently drop every
/// non-English translation. ``reviewTitle`` is already formatted app-side with
/// the extension's display name via `String.localizedStringWithFormat`.
public struct ExtensionAccessReviewSheetStrings: Sendable {
    /// Sheet title, already formatted with the extension's display name
    /// ("Review access for <name>").
    public let reviewTitle: String
    /// Explanatory copy below the title.
    public let reviewDetail: String
    /// Label for the configuration detail row.
    public let manifestLabel: String
    /// Label for the keep-limited (cancel) button.
    public let keepLimited: String
    /// Label for the allow-requested-access (default) button.
    public let allow: String

    public init(
        reviewTitle: String,
        reviewDetail: String,
        manifestLabel: String,
        keepLimited: String,
        allow: String
    ) {
        self.reviewTitle = reviewTitle
        self.reviewDetail = reviewDetail
        self.manifestLabel = manifestLabel
        self.keepLimited = keepLimited
        self.allow = allow
    }
}
