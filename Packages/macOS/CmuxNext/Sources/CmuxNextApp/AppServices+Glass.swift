import CmuxNextDesign
import CmuxNextEnergy

extension AppServices {
    /// Resolves the glass mode pages draw (the Debug choice `glass.lens`, Reduce Transparency, the energy
    /// monitor's Low Power Mode) into the theme store, now and on each change; the store repaints every
    /// window, so every web view pushes its theme (`data-glass`) and its wallpaper still again
    /// (plans/cmux-next/glass-lens-DESIGN.md). Runs after the first frame; `seedGlass()` set the launch's
    /// mode, so this repaints only for a change since then.
    func observeGlass() {
        let watch = GlassModeWatch(lowPowerMode: energyMonitor.lowPowerMode) { [themeStore] mode in themeStore.setGlassMode(mode) }
        themeStore.setGlassMode(watch.mode)
        glassWatch = watch
    }

    /// The launch's glass mode, set before any window builds so the first frame draws it (p08-startup-029).
    func seedGlass() {
        themeStore.setGlassMode(GlassLensMode.current(store: .shared, reduceTransparency: .shared,
                                                      lowPowerMode: energyMonitor.lowPowerMode.isEnabled))
    }
}
