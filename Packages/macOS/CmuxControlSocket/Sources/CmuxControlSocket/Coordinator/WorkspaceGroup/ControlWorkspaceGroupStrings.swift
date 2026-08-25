/// The localized workspace-group error messages, supplied by the app
/// conformance so they resolve against the app's `Localizable.xcstrings`.
///
/// The coordinator owns the error-envelope shaping (codes, data), while these
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
    /// `workspaceGroup.error.invalidReferenceWorkspace` — "Reference workspace
    /// must be a member of the target group".
    public let invalidReferenceWorkspace: String
    /// `workspaceGroup.error.closeWorkspacesMustBeBoolean` — explicit
    /// destructive intent must be a JSON boolean.
    public let closeWorkspacesMustBeBoolean: String

    /// Creates the localized message bundle.
    ///
    /// - Parameters:
    ///   - allChildrenAreAnchors: The all-children-are-anchors message.
    ///   - workspaceIsOtherGroupAnchor: The workspace-is-other-group-anchor
    ///     message.
    ///   - invalidReferenceWorkspace: The invalid-reference-workspace message.
    ///   - closeWorkspacesMustBeBoolean: The malformed destructive-intent message.
    public init(
        allChildrenAreAnchors: String,
        workspaceIsOtherGroupAnchor: String,
        invalidReferenceWorkspace: String,
        closeWorkspacesMustBeBoolean: String
    ) {
        self.allChildrenAreAnchors = allChildrenAreAnchors
        self.workspaceIsOtherGroupAnchor = workspaceIsOtherGroupAnchor
        self.invalidReferenceWorkspace = invalidReferenceWorkspace
        self.closeWorkspacesMustBeBoolean = closeWorkspacesMustBeBoolean
    }
}
