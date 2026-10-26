import CmuxNextDesign
import CmuxNextEnergy

extension AppServices {
    /// Resolves the glass mode pages draw (the Debug choice `glass.lens`, Reduce Transparency, the energy
    /// monitor's Low Power Mode) into the theme store, now and on each change; the store repaints every
    /// window, so every web view pushes its theme (`data-glass`) and its wallpaper still again
    /// (plans/cmux-next/glass-lens-DESIGN.md).
    func observeGlass() {
        let watch = GlassModeWatch(lowPowerMode: energyMonitor.lowPowerMode) { [themeStore] mode in themeStore.setGlassMode(mode) }
        themeStore.setGlassMode(watch.mode)
        glassWatch = watch
    }
}
