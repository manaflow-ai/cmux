public import AppKit

public extension NSWindow {
    /// Whether some of this window shows on a display now: AppKit calls it visible
    /// (`occlusionState`) and its frame overlaps a screen. AppKit keeps a window moved off every
    /// display (a frame at -20000,-20000) `.visible`, so occlusion alone kept a video wallpaper
    /// there decoding at full cost (cmux#47019). A move posts no occlusion change: ask again on
    /// demand (the video wallpaper checks every ``BackdropCoverage/interval``).
    ///
    /// - Parameter screens: The displays' frames; nil reads `NSScreen.screens` (tests inject theirs).
    func isShownOnScreen(screens: [CGRect]? = nil) -> Bool {
        occlusionState.contains(.visible) && isOnSomeScreen(screens: screens)
    }

    /// Whether this window's frame overlaps a display (``overlapsScreen(_:screens:)``).
    ///
    /// - Parameter screens: The displays' frames; nil reads `NSScreen.screens` (tests inject theirs).
    func isOnSomeScreen(screens: [CGRect]? = nil) -> Bool {
        Self.overlapsScreen(frame, screens: screens ?? NSScreen.screens.map(\.frame))
    }

    /// Whether `frame` overlaps any of `screens` by more than an edge. With no displays known
    /// (a headless session) nothing is called off screen: the screens-asleep terms cover that.
    nonisolated static func overlapsScreen(_ frame: CGRect, screens: [CGRect]) -> Bool {
        guard !screens.isEmpty else { return true }
        return screens.contains { screen in
            let overlap = screen.intersection(frame)
            return !overlap.isNull && overlap.width > 0 && overlap.height > 0
        }
    }
}
