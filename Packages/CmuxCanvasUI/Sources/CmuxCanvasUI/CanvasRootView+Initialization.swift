import CmuxCanvas

extension CanvasRootView {
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
