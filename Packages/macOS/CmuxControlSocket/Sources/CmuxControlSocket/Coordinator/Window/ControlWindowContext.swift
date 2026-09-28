public import Foundation

/// The window-domain slice of the control-command seam (a constituent of the
/// ``ControlCommandContext`` umbrella).
///
/// The app target (today `TerminalController`, the interim composition owner;
/// later `TerminalControlComposition`) conforms by reading `AppDelegate` /
/// `Workspace` / `TabManager` state. Every method is `@MainActor` because its
/// conformer lives on the main actor and the coordinator runs there too, so
/// these are plain in-isolation calls — the per-read `v2MainSync` hops the
/// legacy command bodies used disappear once a domain moves onto the
/// coordinator.
@MainActor
public protocol ControlWindowContext: AnyObject {
    /// Snapshots every main window for `window.list`, in window order.
    func controlWindowSummaries() -> [ControlWindowSummary]

    /// Resolves the window targeted by the given routing selectors for
    /// `window.current`, mirroring the legacy `v2ResolveTabManager` →
    /// `windowId(for:)` precedence and its two distinct failures.
    ///
    /// - Parameter routing: The pre-resolved routing selectors.
    /// - Returns: The resolution outcome.
    func controlResolveCurrentWindow(routing: ControlRoutingSelectors) -> ControlCurrentWindowResolution

    /// Focuses the window with the given id for `window.focus`.
    ///
    /// - Parameter id: The window to focus.
    /// - Returns: Whether a matching window was found and focused.
    func controlFocusWindow(id: UUID) -> Bool

    /// Creates a new main window and makes it the active tab-manager target for
    /// `window.create` (create + defensive activation, as the legacy body did).
    ///
    /// - Returns: The new window's id, or `nil` if creation failed.
    func controlCreateWindowAndActivate() -> UUID?

    /// Closes the window with the given id for `window.close`.
    ///
    /// - Parameter id: The window to close.
    /// - Returns: Whether a matching window was found and closed.
    func controlCloseWindow(id: UUID) -> Bool

    /// Snapshots every connected display for `window.displays`, in screen order.
    func controlAvailableDisplays() -> [ControlDisplayInfo]

    /// Whether a window with the given id currently exists (for the
    /// `window.display` not-found disambiguation).
    ///
    /// - Parameter id: The window id to test.
    /// - Returns: Whether the window exists.
    func controlWindowExists(id: UUID) -> Bool

    /// Moves one window onto the display matched by `query` for
    /// `window.display`, preserving size.
    ///
    /// - Parameters:
    ///   - id: The window to move.
    ///   - query: The display match query (name, substring, or index).
    /// - Returns: The resolved display name, or `nil` when the window or display
    ///   can't be resolved.
    func controlMoveWindow(id: UUID, toDisplayMatching query: String) -> String?

    /// Moves every main window onto the display matched by `query` for
    /// `window.display`, preserving sizes.
    ///
    /// - Parameter query: The display match query.
    /// - Returns: The resolved display name and moved window ids, or `nil` when
    ///   the display can't be resolved.
    func controlMoveAllWindows(toDisplayMatching query: String) -> ControlMoveAllWindowsResult?
}
