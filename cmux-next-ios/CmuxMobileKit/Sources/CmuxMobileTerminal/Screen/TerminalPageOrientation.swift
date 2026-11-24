#if os(iOS)
import Foundation

/// Whether a terminal page is on screen, settled and taking input: the app
/// turns sideways then (Leo, 2026-11-23: "why do we not have a horizontal
/// mode? this is glaringly obvious"). The page's grid follows the wider
/// screen through its own layout, and the Mac is asked for it as for any
/// resize. The app's orientation owner (`ScreenSharingOrientation`, through
/// the shell) listens with ``onChange``.
@MainActor
public final class TerminalPageOrientation {
    public static let shared = TerminalPageOrientation()

    /// Pages on screen and settled, by the page's own identity.
    private var shown: Set<UUID> = []

    /// Called when ``isShowing`` changes.
    public var onChange: (@MainActor (Bool) -> Void)?

    public var isShowing: Bool { !shown.isEmpty }

    public init() {}

    /// A page is (or is no longer) on screen and settled.
    public func page(_ id: UUID, shows: Bool) {
        let was = isShowing
        if shows { shown.insert(id) } else { shown.remove(id) }
        if was != isShowing { onChange?(isShowing) }
    }
}
#endif
