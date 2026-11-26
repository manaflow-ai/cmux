/// The app-focus-domain slice of the control-command seam (a constituent of the
/// ``ControlCommandContext`` umbrella).
///
/// The app target (today `TerminalController`, the interim composition owner)
/// conforms by reading and mutating the app's `AppFocusState` override and by
/// re-running the `applicationDidBecomeActive` activation path. Every method is
/// `@MainActor` because its conformer lives on the main actor and the
/// coordinator runs there too, so these are plain in-isolation calls — the
/// per-read `v2MainSync` hop the legacy `v2AppSimulateActive` body used
/// disappears once this domain moves onto the coordinator.
@MainActor
public protocol ControlAppFocusContext: AnyObject {
    /// Sets (or clears) the app-focus override for `app.focus_override.set`,
    /// mirroring the legacy `AppFocusState.overrideIsFocused = …` assignment.
    ///
    /// - Parameter focused: `true`/`false` to force the override, or `nil` to
    ///   clear it and fall back to the real `NSApp.isActive` state.
    func controlSetAppFocusOverride(_ focused: Bool?)

    /// Re-runs the `applicationDidBecomeActive` activation path for
    /// `app.simulate_active`, exactly as the legacy body did by posting an
    /// `NSApplication.didBecomeActiveNotification` to `AppDelegate.shared`.
    func controlSimulateAppActive()
}
