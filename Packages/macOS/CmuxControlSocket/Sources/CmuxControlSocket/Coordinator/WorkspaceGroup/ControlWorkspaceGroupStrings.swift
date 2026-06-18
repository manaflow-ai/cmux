/// The localized workspace-group error messages, supplied by the app
/// conformance so they resolve against the app's `Localizable.xcstrings`.
///
/// The coordinator owns the error-envelope shaping (codes, data) but these two
/// messages must keep their existing keys + default values and their per-locale
/// translations. Resolving `String(localized:)` inside the package would bind to
/// the package bundle, which lacks these keys, silently dropping the non-English
/// variants — so the app passes the already-resolved strings across the seam
/// instead. (Reference pattern: ``ControlNotificationStrings``.)
public struct ControlWorkspaceGroupStrings: Sendable, Equatable {
    /// `workspaceGroup.error.allChildrenAreAnchors` — "All requested children
    /// are ineligible because they are already group anchors; ungroup them
    /// first".
    public let allChildrenAreAnchors: String
    /// `workspaceGroup.error.workspaceIsOtherGroupAnchor` — "Workspace is the
    /// anchor of another group; ungroup it first".
    public let workspaceIsOtherGroupAnchor: String

    /// Creates the localized message bundle.
    ///
    /// - Parameters:
    ///   - allChildrenAreAnchors: The all-children-are-anchors message.
    ///   - workspaceIsOtherGroupAnchor: The workspace-is-other-group-anchor
    ///     message.
    public init(
        allChildrenAreAnchors: String,
        workspaceIsOtherGroupAnchor: String
    ) {
        self.allChildrenAreAnchors = allChildrenAreAnchors
        self.workspaceIsOtherGroupAnchor = workspaceIsOtherGroupAnchor
    }
}
