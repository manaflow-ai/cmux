import CmuxNextDesign
import CmuxNextEnergy

extension AppServices {
    /// Starts the app's one display-options observer (``AppearanceSignals``), then resolves the glass mode pages draw
    /// (`glass.lens`, Reduce Transparency, Low Power Mode) into the theme store, now and on each change (glass-lens-DESIGN.md).
    func observeGlass() {
        appearance.observeDisplayOptions(through: workspaceEvents)
        let watch = GlassModeWatch(signals: appearance, lowPowerMode: energyMonitor.lowPowerMode) { [themeStore] mode in
            themeStore.setGlassMode(mode)
        }
        themeStore.setGlassMode(watch.mode)
        glassWatch = watch
    }
}
