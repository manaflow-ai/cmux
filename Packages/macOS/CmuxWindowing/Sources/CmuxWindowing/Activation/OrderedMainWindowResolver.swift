public import AppKit

/// Resolves the single "current" main-window projection by walking the
/// application's window order, deduplicating by window identity, and returning
/// the first window that projects, falling back to a caller-supplied default.
///
/// This is the ordering-and-dedup kernel that
/// `AppDelegate.currentScriptableMainWindow()` open-coded: prefer
/// `NSApp.keyWindow`, then `NSApp.mainWindow`, then each window in
/// `NSApp.orderedWindows`, skipping any window already visited (by
/// `ObjectIdentifier`), and projecting each candidate through an app-supplied
/// closure that resolves the window to the app-target scriptable state. If no
/// ordered window projects, the resolver returns the caller's fallback (the
/// app's first scriptable window in its own deterministic order). The policy
/// names no app-target type: candidates are abstract `NSWindow` handles and the
/// result is a generic `Projection`, mirroring ``MainWindowActivationResolver``
/// and ``RecoverableWindowRouteLedger/appendingDeduplicatedProjections(into:seen:project:)``,
/// which lifted the sibling window-ordering policies out of the same god file.
///
/// Design: the resolver holds no mutable state. Its window sources are
/// `@MainActor` closures because every source it reads (`NSApp.keyWindow`,
/// `NSApp.mainWindow`, `NSApp.orderedWindows`) is main-bound, so the type is
/// `@MainActor` and is a real instance constructed at the composition root, not
/// a static-method namespace. The `project`/`fallback` closures stay app-side so
/// the irreducible `NSWindow`-to-scriptable-state resolution (which reaches into
/// app-target window/tab/surface registries) remains in the app target.
@MainActor
public struct OrderedMainWindowResolver {
    /// The current key window, or `nil`.
    private let keyWindow: @MainActor () -> NSWindow?

    /// The current main window, or `nil`.
    private let mainWindow: @MainActor () -> NSWindow?

    /// All application windows in front-to-back order.
    private let orderedWindows: @MainActor () -> [NSWindow]

    /// Creates an ordered main-window resolver.
    ///
    /// - Parameters:
    ///   - keyWindow: the current key window.
    ///   - mainWindow: the current main window.
    ///   - orderedWindows: all application windows in front-to-back order.
    public init(
        keyWindow: @escaping @MainActor () -> NSWindow?,
        mainWindow: @escaping @MainActor () -> NSWindow?,
        orderedWindows: @escaping @MainActor () -> [NSWindow]
    ) {
        self.keyWindow = keyWindow
        self.mainWindow = mainWindow
        self.orderedWindows = orderedWindows
    }

    /// Returns the first window projection in resolution order, or `fallback()`
    /// if no ordered window projects.
    ///
    /// The window order is key window, then main window, then every window in
    /// front-to-back order; each window is visited at most once (deduplicated by
    /// `ObjectIdentifier`), and `nil` windows are skipped. `project` runs per
    /// candidate and returns the window's `Projection` when it resolves or `nil`
    /// when it does not; the first non-`nil` result wins. When no candidate
    /// projects, `fallback` supplies the result (the app's first scriptable
    /// window in its own deterministic order), faithfully reproducing the legacy
    /// `scriptableMainWindows().first` tail.
    public func resolve<Projection>(
        project: (NSWindow) -> Projection?,
        fallback: () -> Projection?
    ) -> Projection? {
        var seen: Set<ObjectIdentifier> = []

        func attempt(_ window: NSWindow?) -> Projection? {
            guard let window else { return nil }
            guard seen.insert(ObjectIdentifier(window)).inserted else { return nil }
            return project(window)
        }

        if let projection = attempt(keyWindow()) {
            return projection
        }
        if let projection = attempt(mainWindow()) {
            return projection
        }
        for window in orderedWindows() {
            if let projection = attempt(window) {
                return projection
            }
        }
        return fallback()
    }
}
