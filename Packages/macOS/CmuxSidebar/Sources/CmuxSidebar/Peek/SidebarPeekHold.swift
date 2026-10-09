/// Reasons the peek panel must stay open regardless of where the pointer is.
///
/// Pointer-driven panels are usually ruined by the cases where the pointer is
/// legitimately somewhere else: a context menu the user opened from a row, a
/// text field they are typing into, a drag they are carrying. Each of those
/// registers a hold, and dismissal is refused while any hold is set.
public struct SidebarPeekHold: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    /// Creates a hold set from its raw bits.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The pointer is inside the panel.
    public static let pointerInsidePanel = SidebarPeekHold(rawValue: 1 << 0)
    /// A context menu opened from the panel is showing.
    ///
    /// The menu is its own window, so the pointer leaves the panel the moment
    /// the menu appears. Without this hold the panel dismisses out from under
    /// the menu the user just opened.
    public static let contextMenuOpen = SidebarPeekHold(rawValue: 1 << 1)
    /// A text field in the panel has keyboard focus, such as the filter field
    /// or an inline rename.
    public static let keyboardFocusInside = SidebarPeekHold(rawValue: 1 << 2)
    /// A drag is in flight over the panel.
    public static let dragInFlight = SidebarPeekHold(rawValue: 1 << 3)

    /// Whether any hold is set.
    public var isHolding: Bool {
        !isEmpty
    }
}
