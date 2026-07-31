/// Decides whether temporary browser hosting may restore an earlier host and geometry.
public struct BrowserViewportRestorationPolicy: Equatable, Sendable {
    /// Whether teardown should reattach the browser to its previous host.
    public let shouldRestorePreviousHost: Bool

    /// Whether teardown should restore the previous frame and bounds verbatim.
    public let shouldPreservePreviousGeometry: Bool

    /// Creates a restoration policy from the browser's host ownership state.
    ///
    /// - Parameters:
    ///   - temporaryHostIsCurrent: Whether the temporary render host is still current.
    ///   - hasPreviousHost: Whether there is an earlier host to restore.
    ///   - hasVisibleWebKitCompanion: Whether that host has a visible WebKit-managed companion layout.
    public init(
        temporaryHostIsCurrent: Bool,
        hasPreviousHost: Bool,
        hasVisibleWebKitCompanion: Bool
    ) {
        shouldRestorePreviousHost = temporaryHostIsCurrent
        shouldPreservePreviousGeometry = !hasPreviousHost || hasVisibleWebKitCompanion
    }
}
