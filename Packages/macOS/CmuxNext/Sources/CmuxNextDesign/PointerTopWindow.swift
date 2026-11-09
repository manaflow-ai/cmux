public import AppKit

/// A window whose frame is larger than what it draws: a clear band around its content (the hover
/// card's shadow and slide room, `HoverCardPanel.windowMargin`) that the pointer passes through to
/// the window below.
///
/// The window server answers "which window is under the pointer" by frame, so over the band it
/// names this window, and every hover that asks whether its own window is on top read as covered.
/// The update card's x hid whenever the pointer was in the band of its open notes card, which
/// reaches over the update card's top right corner (Aziz 2026-11-09: "The x here doesnt appear when
/// the cursor is in the top right ... in certain hover positions the x doesnt appear whiel it does
/// in others"). Clicks there already went to the window below (`HoverCardPanel+ClickThrough`);
/// the hover did not.
@MainActor
public protocol PointerClearBandWindow: NSWindow {
    /// The pointer at `screenPoint` passes through this window to the one below it.
    func passesPointer(atScreen screenPoint: NSPoint) -> Bool
}

/// The window on top under a screen point for hover and cursor checks: the window server's answer,
/// skipping each window that passes the pointer through there (``PointerClearBandWindow``).
@MainActor
public enum PointerTopWindow {
    /// How many clear-band windows one answer looks through (one hover card today).
    static let maxPassThroughs = 4

    /// The views of each window whose hover follows the pointer on its own (the layout's dividers),
    /// told directly when the pointer moves in a clear band over that window: the window hears no
    /// pointer event of its own there. Weak: a follower that goes leaves by itself.
    private static let followers = NSMapTable<NSWindow, NSHashTable<AnyObject>>.weakToStrongObjects()

    /// `follower` hears the pointer move in a clear band over `window` until it goes or follows another.
    public static func follow(_ window: NSWindow, with follower: any PointerBandFollower) {
        for case let other? in followers.objectEnumerator()?.allObjects as? [NSHashTable<AnyObject>] ?? [] {
            other.remove(follower)
        }
        let table = followers.object(forKey: window) ?? NSHashTable<AnyObject>.weakObjects()
        table.add(follower)
        followers.setObject(table, forKey: window)
    }

    /// The pointer moved, entered or left a clear band over `window`: its followers recompute.
    static func pointerMovedInBand(over window: NSWindow) {
        for case let follower as any PointerBandFollower in followers.object(forKey: window)?.allObjects ?? [] {
            follower.pointerMovedInBand()
        }
    }

    /// The number of the window on top at `screenPoint` (0: none of any app).
    public static func number(at screenPoint: NSPoint) -> Int {
        number(at: screenPoint,
               below: { NSWindow.windowNumber(at: $0, belowWindowWithWindowNumber: $1) },
               window: { NSApp.window(withWindowNumber: $0) })
    }

    /// ``number(at:)`` with the window server and the app's window list given (tests).
    static func number(at screenPoint: NSPoint, below: (NSPoint, Int) -> Int, window: (Int) -> NSWindow?) -> Int {
        var top = below(screenPoint, 0)
        var passes = 0
        while top > 0, passes < maxPassThroughs,
              let band = window(top) as? any PointerClearBandWindow, band.passesPointer(atScreen: screenPoint) {
            passes += 1
            top = below(screenPoint, top)
        }
        return top
    }
}

/// A view whose hover follows the pointer on its own (``PointerTopWindow/follow(_:with:)``).
@MainActor
public protocol PointerBandFollower: AnyObject {
    func pointerMovedInBand()
}
