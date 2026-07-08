public import AppKit

/// Reads live `NSScreen` / `NSWindow` state into the pure
/// ``SessionDisplayGeometry`` value type that session-restore frame math
/// consumes.
///
/// Faithful lift of `AppDelegate.currentDisplayGeometries()` and the
/// screen-resolution half of `AppDelegate.displaySnapshot(for:)` from the
/// AppDelegate god file. The reading is unchanged: every attached screen maps
/// to a ``SessionDisplayGeometry`` in `NSScreen.screens` order, the fallback is
/// `NSScreen.main` (or the first screen when there is no main), and a window's
/// owning screen is `window.screen` or the first screen whose frame intersects
/// the window frame.
///
/// The app target maps these geometry values into its own `Codable` display
/// snapshot before persisting, so the on-disk wire format stays owned by the
/// app target; this reader only produces the runtime geometry inputs.
///
/// A stateless value: it reads only live AppKit screen/window state handed to
/// each call, so it is a `Sendable` struct rather than an actor. The methods
/// are `@MainActor` because they read main-actor `NSScreen` / `NSWindow`
/// properties.
public struct DisplayGeometryReader: Sendable {
    /// Creates a display-geometry reader.
    public init() {}

    /// The geometry of every attached screen, plus the fallback screen to clamp
    /// onto when a saved frame's origin display is gone.
    ///
    /// - Returns: `available` lists every screen in `NSScreen.screens` order;
    ///   `fallback` is `NSScreen.main`, or the first attached screen when there
    ///   is no main screen, or `nil` when no screens are attached.
    @MainActor
    public func currentDisplayGeometries() -> (
        available: [SessionDisplayGeometry],
        fallback: SessionDisplayGeometry?
    ) {
        let available = NSScreen.screens.map { screen in
            SessionDisplayGeometry(
                displayID: screen.cmuxDisplayID,
                stableID: screen.cmuxStableDisplayKey,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        let fallback = (NSScreen.main ?? NSScreen.screens.first).map { screen in
            SessionDisplayGeometry(
                displayID: screen.cmuxDisplayID,
                stableID: screen.cmuxStableDisplayKey,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
        return (available, fallback)
    }

    /// The geometry of the screen a window currently occupies, or `nil` when the
    /// window is `nil` or no attached screen contains it.
    ///
    /// The owning screen is `window.screen`, falling back to the first screen
    /// whose frame intersects the window frame. The app target maps the returned
    /// geometry into its persisted display snapshot.
    @MainActor
    public func screenGeometry(for window: NSWindow?) -> SessionDisplayGeometry? {
        guard let window else { return nil }
        let screen = window.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(window.frame) })
        guard let screen else { return nil }
        return SessionDisplayGeometry(
            displayID: screen.cmuxDisplayID,
            stableID: screen.cmuxStableDisplayKey,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }
}
