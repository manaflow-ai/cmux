public import CmuxTerminalCore

/// The app-side collaborators the cold engine runtime reaches up to during a
/// configuration reload and a post-reload surface refresh.
///
/// This inverts the `AppDelegate.shared` reach-ups the legacy `GhosttyApp`
/// engine orchestration performed (`reloadCmuxConfigStores(source:)` and
/// `refreshTerminalSurfacesAfterGhosttyConfigReload(source:preferredColorScheme:)`).
/// The app's delegate conforms and is injected into ``GhosttyEngineRuntime`` at
/// the composition root, so the engine never names the `AppDelegate` singleton.
///
/// Isolation: every reach-up the legacy bodies performed ran on the main thread
/// (the reload path marshals to main via `performOnMain`/`DispatchQueue.main`),
/// so the seam is `@MainActor`.
///
/// TODO(refactor): `AppDelegate` (a god type in the app target) must declare
/// conformance to this protocol; that file is owned by another concurrent
/// slice, so the conformance is added by the integrator. The two witnesses are
/// the existing `AppDelegate.reloadCmuxConfigStores(source:)` and
/// `AppDelegate.refreshTerminalSurfacesAfterGhosttyConfigReload(source:preferredColorScheme:)`.
@MainActor
public protocol ConfigReloadHosting: AnyObject {
    /// Re-reads cmux's per-window configuration stores after a Ghostty config
    /// reload (was `AppDelegate.shared?.reloadCmuxConfigStores(source:)`).
    func reloadCmuxConfigStores(source: String)

    /// Refreshes live terminal surfaces after a Ghostty config reload (was
    /// `AppDelegate.shared?.refreshTerminalSurfacesAfterGhosttyConfigReload(...)`).
    func refreshTerminalSurfacesAfterGhosttyConfigReload(
        source: String,
        preferredColorScheme: GhosttyConfig.ColorSchemePreference
    )
}
