import CmuxCanvas

extension CanvasRootView {
    /// Creates a canvas root view using the production clock for minimap auto-hide timing.
    public convenience init(
        model: CanvasModel,
        commandScrollHintText: String,
        callbacks: CanvasHostCallbacks,
        themeProvider: @escaping () -> CanvasTheme
    ) {
        self.init(
            model: model,
            commandScrollHintText: commandScrollHintText,
            callbacks: callbacks,
            themeProvider: themeProvider,
            minimapClock: ContinuousClock()
        )
    }
}
