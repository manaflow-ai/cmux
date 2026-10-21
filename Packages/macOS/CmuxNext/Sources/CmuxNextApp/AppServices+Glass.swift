import CmuxNextDesign

extension AppServices {
    /// Repaints every window when the glass mode pages draw changes (`appearance.glass`, Reduce
    /// Transparency, Low Power Mode): every web view pushes its theme (`data-glass`) and its
    /// wallpaper still again (plans/cmux-next/glass-lens-DESIGN.md).
    func observeGlass() {
        glassWatch = GlassModeWatch { ThemeStore.shared.repaintAll() }
    }
}
