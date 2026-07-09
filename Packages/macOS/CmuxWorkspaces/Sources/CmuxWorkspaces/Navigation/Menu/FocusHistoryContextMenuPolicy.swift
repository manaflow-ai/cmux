/// The focus-history context-menu content policy: how many entries the
/// right-click context menu previews before it offers a "Show Full History"
/// entry that re-presents the unbounded list.
///
/// This owns the menu-content decision the AppDelegate context-menu shim used
/// to encode as a bare `12` constant. The app target keeps the AppKit `NSMenu`
/// construction and the localized titles; it asks this policy for the
/// `maxItemCount` to pass to ``FocusHistoryNavigating/focusHistoryMenuSnapshot(direction:maxItemCount:)``.
public struct FocusHistoryContextMenuPolicy: Equatable, Sendable {
    /// The maximum number of items shown before the menu is truncated and the
    /// "Show Full History" entry appears. The legacy value is 12.
    public let previewLimit: Int

    /// Creates a policy.
    ///
    /// - Parameter previewLimit: the preview truncation cap (legacy default 12).
    public init(previewLimit: Int = 12) {
        self.previewLimit = previewLimit
    }

    /// The `maxItemCount` to request for a menu snapshot.
    ///
    /// - Parameter showingFullHistory: when `true` the menu is presenting the
    ///   unbounded list, so no truncation applies (`nil`); otherwise the
    ///   ``previewLimit`` caps the preview.
    /// - Returns: `nil` for the full list, or ``previewLimit`` for the preview.
    public func maxItemCount(showingFullHistory: Bool) -> Int? {
        showingFullHistory ? nil : previewLimit
    }
}
