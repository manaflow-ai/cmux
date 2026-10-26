public import AppKit
public import QuartzCore

/// A ``DisplayClock``'s vsync hub link and its window resolvers: the display a window is on and whether
/// anyone sees it. Screen links stay in DisplayClock.swift, the one file that may make one.
extension DisplayClock {
    /// A link that rides `hub`'s display thread: each vsync of the display is one main post that ticks the clock.
    static func hubLink(_ hub: VSyncHub, _ display: CGDirectDisplayID, _ clock: DisplayClock) -> (any FrameLink)? {
        hub.mainLink(display: display) { [weak clock] tick in
            clock?.displayDidFire(display, timestamp: tick.timestamp, refreshInterval: tick.refreshInterval,
                                  targetTimestamp: tick.targetTimestamp)
        }
    }

    /// A window can be seen unless it is miniaturized, the app is hidden, or it is on screen with no
    /// visible part. A window not ordered in (still being built) has no occlusion state yet and counts
    /// as seen.
    static func systemIsVisible(_ window: NSWindow) -> Bool {
        if window.isMiniaturized || NSApp?.isHidden == true { return false }
        return !window.isVisible || window.occlusionState.contains(.visible)
    }

    static func systemDisplay(_ window: NSWindow?) -> CGDirectDisplayID? {
        (window?.screen ?? NSScreen.main ?? NSScreen.screens.first).flatMap(number(of:))
    }

    static func number(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
