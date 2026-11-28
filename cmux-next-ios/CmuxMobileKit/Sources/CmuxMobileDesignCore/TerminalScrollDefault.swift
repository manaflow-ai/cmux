/// The terminal's scroll default, read by both the terminal (`CmuxMobilePreferences.terminalPlainScroll`)
/// and Settings (`SettingsStore.terminalPlainScroll`). One constant: two copies let the toggle show one
/// value while the terminal used the other.
///
/// On: a drag in a full-screen app scrolls the rows the phone already has, like any iOS page, instead
/// of sending the app one wheel line at a time. Leo, 2026-11-25: "Btw how do you feel about me making it
/// just a normal iOS scroll instead of like by line scroll in the terminal view?" and "we can just treat
/// the scroll like any pedestrian scroll." Off (Settings → Terminal → Plain Scroll in Full-Screen Apps)
/// keeps the line-by-line wheel scroll.
///
/// Off by default again (iOS regression row 18): with it on, a drag in a full-screen app opened the
/// phone's own re-render of the screen. Aziz, 2026-11-26: "I prefer that you take it back to the old
/// behavior ... you shouldnt be trying to rerender the tui on your own"; Leo: "Ok". A stored On stays.
public enum TerminalScrollDefault {
    public static let plainScroll = false
}

#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif

/// The plain scroll's pure math (no UI framework), so Linux CI tests it.
public enum TerminalScrollMath {
    /// UIScrollView's rubber band: `offset` past the edge shows as less, never more than `dimension`.
    public static func rubberBand(_ offset: CGFloat, dimension: CGFloat) -> CGFloat {
        guard dimension > 0, offset > 0 else { return 0 }
        return (1 - 1 / (offset * 0.55 / dimension + 1)) * dimension
    }
}
