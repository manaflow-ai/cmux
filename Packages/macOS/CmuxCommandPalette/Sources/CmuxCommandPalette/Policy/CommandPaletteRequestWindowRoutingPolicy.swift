public import AppKit

/// Decides whether a command-palette request, which may be addressed to a
/// specific window or broadcast to all of them, should be handled by the
/// surface observing `observedWindow`. A request resolves to exactly one
/// target window: the explicitly requested window when present, otherwise the
/// key window, otherwise the main window. The observing surface handles the
/// request only when it owns that resolved target.
public struct CommandPaletteRequestWindowRoutingPolicy {
    /// The window this command-palette surface is observing.
    public let observedWindow: NSWindow?
    /// The window the request explicitly targets, if any.
    public let requestedWindow: NSWindow?
    /// The application's current key window.
    public let keyWindow: NSWindow?
    /// The application's current main window.
    public let mainWindow: NSWindow?

    /// Captures the request routing inputs to evaluate.
    public init(
        observedWindow: NSWindow?,
        requestedWindow: NSWindow?,
        keyWindow: NSWindow?,
        mainWindow: NSWindow?
    ) {
        self.observedWindow = observedWindow
        self.requestedWindow = requestedWindow
        self.keyWindow = keyWindow
        self.mainWindow = mainWindow
    }

    /// Whether the observing surface should handle the request.
    public var shouldHandle: Bool {
        guard let observedWindow else { return false }
        if let requestedWindow {
            return requestedWindow === observedWindow
        }
        if let keyWindow {
            return keyWindow === observedWindow
        }
        if let mainWindow {
            return mainWindow === observedWindow
        }
        return false
    }
}
