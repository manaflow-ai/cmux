public import AppKit

/// Resolves which `NSWindow` the app should activate or operate on for
/// application-visibility flows (socket activate, settings presentation,
/// menu-bar show, global-hotkey toggle, application-hide capture).
///
/// This is the window-domain selection/ordering policy lifted byte-for-byte
/// from `AppDelegate.preferredMainWindowForVisibilityActivation()` and
/// `AppDelegate.mainWindowsForVisibilityController()`. The policy reads only
/// abstract window handles plus three predicates; it owns no AppKit hosting
/// (no `NSStatusItem`, no `MenuBarExtra`, no visibility-controller calls), which
/// stay app-target shims. AppDelegate constructs this with the live window
/// sources and forwards.
///
/// Design: the resolver holds no mutable state. Its inputs are `@MainActor`
/// closures because every source it reads (`NSApp.keyWindow`, the per-window
/// context snapshot, a window's `isVisible`/`isMiniaturized`) is main-bound, so
/// the type is `@MainActor` and is a real instance constructed at the
/// composition root, not a static-method namespace.
@MainActor
public struct MainWindowActivationResolver {
    /// Supplies the per-window context windows in session-snapshot order, each
    /// already resolved to its live `NSWindow` (already de-duplicated by the
    /// caller's snapshot ordering; `nil` entries dropped here are contexts whose
    /// window could not be resolved).
    private let sortedContextWindows: @MainActor () -> [NSWindow]

    /// The current key window, or `nil`.
    private let keyWindow: @MainActor () -> NSWindow?

    /// The current main window, or `nil`.
    private let mainWindow: @MainActor () -> NSWindow?

    /// All application windows (used to union in main-terminal windows that have
    /// no tracked context).
    private let allWindows: @MainActor () -> [NSWindow]

    /// Whether a window is one of the app's main terminal windows.
    private let isMainTerminalWindow: @MainActor (NSWindow) -> Bool

    /// Whether a window is currently visible.
    private let isVisible: @MainActor (NSWindow) -> Bool

    /// Whether a window is currently miniaturized.
    private let isMiniaturized: @MainActor (NSWindow) -> Bool

    /// Creates an activation resolver.
    ///
    /// - Parameters:
    ///   - sortedContextWindows: per-window context windows in session-snapshot
    ///     order, resolved to live `NSWindow`s.
    ///   - keyWindow: the current key window.
    ///   - mainWindow: the current main window.
    ///   - allWindows: all application windows.
    ///   - isMainTerminalWindow: main-terminal-window predicate.
    ///   - isVisible: window-visible predicate.
    ///   - isMiniaturized: window-miniaturized predicate.
    public init(
        sortedContextWindows: @escaping @MainActor () -> [NSWindow],
        keyWindow: @escaping @MainActor () -> NSWindow?,
        mainWindow: @escaping @MainActor () -> NSWindow?,
        allWindows: @escaping @MainActor () -> [NSWindow],
        isMainTerminalWindow: @escaping @MainActor (NSWindow) -> Bool,
        isVisible: @escaping @MainActor (NSWindow) -> Bool,
        isMiniaturized: @escaping @MainActor (NSWindow) -> Bool
    ) {
        self.sortedContextWindows = sortedContextWindows
        self.keyWindow = keyWindow
        self.mainWindow = mainWindow
        self.allWindows = allWindows
        self.isMainTerminalWindow = isMainTerminalWindow
        self.isVisible = isVisible
        self.isMiniaturized = isMiniaturized
    }

    /// The window the app should prefer when activating itself for visibility.
    ///
    /// Selection order, byte-faithful to the legacy method: the key window if it
    /// is a main terminal window; otherwise the main window if it is a main
    /// terminal window; otherwise the first session-snapshot context window that
    /// is visible and not miniaturized; otherwise the first session-snapshot
    /// context window.
    public func preferredMainWindowForVisibilityActivation() -> NSWindow? {
        if let keyWindow = keyWindow(),
           isMainTerminalWindow(keyWindow) {
            return keyWindow
        }
        if let mainWindow = mainWindow(),
           isMainTerminalWindow(mainWindow) {
            return mainWindow
        }
        let contextWindows = sortedContextWindows()
        if let visibleWindow = contextWindows.first(where: { window in
            isVisible(window) && !isMiniaturized(window)
        }) {
            return visibleWindow
        }
        return contextWindows.first
    }

    /// All windows the visibility controller should operate on: the
    /// session-snapshot context windows, then any other main terminal windows
    /// not already included, preserving order and de-duplicating by identity.
    public func mainWindowsForVisibilityController() -> [NSWindow] {
        var windows: [NSWindow] = []
        for window in sortedContextWindows() {
            if !windows.contains(where: { $0 === window }) {
                windows.append(window)
            }
        }
        for window in allWindows() where isMainTerminalWindow(window) {
            if !windows.contains(where: { $0 === window }) {
                windows.append(window)
            }
        }
        return windows
    }
}
