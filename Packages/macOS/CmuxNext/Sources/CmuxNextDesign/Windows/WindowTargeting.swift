public import AppKit

/// The cmux window a window action (Zoom, Select Next/Previous Window, Close
/// All Windows) acts on: the key window, else the frontmost cmux window,
/// never simply the first window opened (nxdog47: Zoom hit the first window
/// while the app was in the background).
public struct WindowTargeting {
    public var keyWindow: NSWindow?
    /// Every app window, front to back (`NSApp.orderedWindows`).
    public var ordered: [NSWindow]
    /// The cmux shell windows, in the order they were opened.
    public var shells: [NSWindow]

    public init(keyWindow: NSWindow?, ordered: [NSWindow], shells: [NSWindow]) {
        (self.keyWindow, self.ordered, self.shells) = (keyWindow, ordered, shells)
    }

    @MainActor
    public static func current(_ shells: [NSWindow]) -> WindowTargeting {
        WindowTargeting(keyWindow: NSApp.keyWindow, ordered: NSApp.orderedWindows, shells: shells)
    }

    public var target: NSWindow? {
        if let keyWindow, shells.contains(where: { $0 === keyWindow }) { return keyWindow }
        return frontToBack.first
    }

    /// The shell windows front to back; ones `ordered` does not list (not on screen) last.
    private var frontToBack: [NSWindow] {
        let shown = ordered.filter { window in shells.contains { $0 === window } }
        return shown + shells.filter { window in !shown.contains { $0 === window } }
    }

    /// The shell window `offset` places from the target in the order of `shells`, wrapping; nil with fewer
    /// than two windows. That order does not change when a window comes to the front, so repeated presses
    /// reach each window; front to back, the window a press leaves is next again and a third is not reached.
    public func cycled(_ offset: Int) -> NSWindow? {
        guard shells.count > 1 else { return nil }
        let current = target.flatMap { window in shells.firstIndex { $0 === window } } ?? 0
        return shells[((current + offset) % shells.count + shells.count) % shells.count]
    }

    /// Closes `window` the way its close button would (its delegate's
    /// `windowShouldClose` decides), also when the window has no close button.
    @MainActor
    public static func close(_ window: NSWindow) {
        guard window.delegate?.windowShouldClose?(window) ?? true else { return }
        window.close()
    }
}
