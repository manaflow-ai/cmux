#if DEBUG
import CmuxNextDesign
import CmuxNextSettingsWindow

/// DEBUG ONLY: the UI shell's App scenes (Prototypes/UiLayerHost `cmux-ui-app --shoot`), so a push that changes
/// CmuxNextApp gets a before and after picture from an incremental build of this module. Each opener draws the App's
/// own composition of a window over a fresh ``DesignSettings`` that saves nothing: no daemon, no services.
public enum AppUiShellScenes {
    /// The Density Playground with the rows ``DensityHandlers`` gives it; returns its opener (the opener holds it).
    public static func densityPlayground() -> @MainActor () -> Void {
        let playground = DensityPlaygroundWindow(model: DensityPlaygroundModel(
            entries: DensityHandlers.playgroundEntries(), design: DesignSettings(), isManaged: { true },
            persist: { _, _ in }))
        return { playground.show() }
    }
}
#endif
