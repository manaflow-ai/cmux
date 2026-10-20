#if DEBUG
/// The right-sidebar reveal state `debug.right_sidebar.focus` reports back
/// (the Sendable shape of `AppDelegate.debugRevealRightSidebarInActiveMainWindow`'s
/// tuple result, plus the validated mode raw value).
public struct ControlDebugRightSidebarFocusState: Sendable, Equatable {
    /// Whether the sidebar was revealed (the payload's `focused` key).
    public let revealed: Bool
    /// Whether first-item focus was applied.
    public let focusApplied: Bool
    /// Whether a sidebar context was found.
    public let contextFound: Bool
    /// Whether sidebar state was found.
    public let stateFound: Bool
    /// Whether the sidebar is visible.
    public let visible: Bool
    /// The active sidebar mode raw value, if known.
    public let activeMode: String?
    /// The validated requested mode raw value (the payload's `mode` key).
    public let mode: String

    /// Creates a state snapshot.
    ///
    /// - Parameters:
    ///   - revealed: Whether the sidebar was revealed.
    ///   - focusApplied: Whether first-item focus was applied.
    ///   - contextFound: Whether a sidebar context was found.
    ///   - stateFound: Whether sidebar state was found.
    ///   - visible: Whether the sidebar is visible.
    ///   - activeMode: The active sidebar mode raw value, if known.
    ///   - mode: The validated requested mode raw value.
    public init(
        revealed: Bool,
        focusApplied: Bool,
        contextFound: Bool,
        stateFound: Bool,
        visible: Bool,
        activeMode: String?,
        mode: String
    ) {
        self.revealed = revealed
        self.focusApplied = focusApplied
        self.contextFound = contextFound
        self.stateFound = stateFound
        self.visible = visible
        self.activeMode = activeMode
        self.mode = mode
    }
}
#endif
