public import AppKit

/// Decides whether a window-scoped command-palette request notification should
/// be handled by a particular observed window.
///
/// Command-palette requests are broadcast through `NotificationCenter` and every
/// open window observes them. The request optionally names a target window in
/// its `object`; when it does, only that exact window acts. When it does not,
/// the request falls back to the key window, then the main window. The match is
/// `NSWindow` reference identity, so two windows never both act on one request.
public struct CommandPaletteWindowDispatchPolicy {
    /// The window evaluating the request (the receiver of the notification).
    public let observedWindow: NSWindow?
    /// The window the request explicitly targeted, if any.
    public let requestedWindow: NSWindow?
    /// The application's current key window.
    public let keyWindow: NSWindow?
    /// The application's current main window.
    public let mainWindow: NSWindow?

    /// Captures the window context of a single command-palette request.
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

    /// Whether the observed window should handle this command-palette request.
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
