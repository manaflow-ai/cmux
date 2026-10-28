import CmuxNextDesign
import CmuxNextEnergy

extension AppServices {
    /// Starts the app's one display-options observer (``AppearanceSignals``), then resolves the glass mode pages draw
    /// (`glass.lens`, Reduce Transparency, Low Power Mode) into the theme store, now and on each change (glass-lens-DESIGN.md).
    /// Runs after the first frame; `seedGlass()` set the launch's mode, so this repaints only for a change since then.
    func observeGlass() {
        appearance.observeDisplayOptions(through: workspaceEvents)
        let watch = GlassModeWatch(signals: appearance, lowPowerMode: energyMonitor.lowPowerMode, mainWork: mainWork) { [themeStore] mode in
            themeStore.setGlassMode(mode)
        }
        themeStore.setGlassMode(watch.mode)
        glassWatch = watch
    }

    /// The launch's glass mode, set before any window builds so the first frame draws it.
    func seedGlass() {
        themeStore.setGlassMode(GlassLensMode.current(store: .shared, reduceTransparency: .shared,
                                                      lowPowerMode: energyMonitor.lowPowerMode.isEnabled))
    }
}
