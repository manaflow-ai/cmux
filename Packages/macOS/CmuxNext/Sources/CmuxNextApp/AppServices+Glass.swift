import AppKit
import CmuxNextDesign
import CmuxNextEnergy
import CmuxNextWakeups

extension AppServices {
    /// Starts the app's one display-options observer (``AppearanceSignals``), then resolves the glass mode pages draw
    /// (`glass.lens`, Reduce Transparency, Low Power Mode) into the theme store, now and on each change (glass-lens-DESIGN.md).
    func observeGlass() {
        // raw-observer-allow: the AppEvents fan-out itself, the app's one observer of the display notice
        DesignSettings.shared.signals.observeDisplayOptions(through: AppEvents(center: NSWorkspace.shared.notificationCenter))
        let watch = GlassModeWatch(lowPowerMode: energyMonitor.lowPowerMode) { [themeStore] mode in themeStore.setGlassMode(mode) }
        themeStore.setGlassMode(watch.mode)
        glassWatch = watch
    }
}
