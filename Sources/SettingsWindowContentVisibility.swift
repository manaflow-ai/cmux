/// Decides whether the Settings window renders its full content or a lightweight
/// placeholder, based on the lifecycle of the underlying `NSWindow`.
///
/// SwiftUI reuses the Settings `Window` scene across close / reopen. The
/// `WindowAccessor` that supplies the window dedupes by the reused `NSWindow`,
/// so it does not fire again on the second open, and the scene's view state
/// persists. Without re-adoption, a window that was forgotten on close (to stop
/// observing it) can never flip back to rendering content — producing a blank
/// window on every open after the first. This value type centralizes that
/// state machine so the close → reopen path can be exercised in isolation.
@MainActor
struct SettingsWindowContentVisibility: Equatable {
    /// Whether the settings content should render. When `false`, callers show a
    /// cheap placeholder instead of the full settings hierarchy.
    private(set) var shouldRenderContent: Bool

    /// Identity of the window currently being observed, if any. Cleared on close.
    private var observedWindow: ObjectIdentifier?

    /// Creates a coordinator that renders content until a lifecycle event hides it.
    init() {
        shouldRenderContent = true
        observedWindow = nil
    }

    /// Adopts the window the scene attached to.
    ///
    /// - Parameters:
    ///   - window: Identity of the attached window.
    ///   - isMiniaturized: Whether that window is currently miniaturized; content
    ///     stays hidden while miniaturized to avoid wasted rendering.
    mutating func windowConfigured(_ window: ObjectIdentifier, isMiniaturized: Bool) {
        observedWindow = window
        shouldRenderContent = !isMiniaturized
    }

    /// Hides content while the observed window is miniaturized.
    mutating func windowDidMiniaturize(_ window: ObjectIdentifier) {
        guard window == observedWindow else { return }
        shouldRenderContent = false
    }

    /// Restores content when the window becomes visible again.
    ///
    /// Re-adopts the window when the previous observation was cleared on close
    /// (the reused-scene case where `WindowAccessor` never fires a second time).
    ///
    /// - Parameters:
    ///   - window: Identity of the window that became visible.
    ///   - isSettingsWindow: Whether that window is the Settings window, used to
    ///     re-adopt it after a prior close cleared the reference.
    mutating func windowDidBecomeVisible(_ window: ObjectIdentifier, isSettingsWindow: Bool) {
        if observedWindow == nil, isSettingsWindow {
            observedWindow = window
        }
        guard window == observedWindow else { return }
        shouldRenderContent = true
    }

    /// Hides content and forgets the window when it closes.
    mutating func windowWillClose(_ window: ObjectIdentifier) {
        guard window == observedWindow else { return }
        shouldRenderContent = false
        observedWindow = nil
    }
}
