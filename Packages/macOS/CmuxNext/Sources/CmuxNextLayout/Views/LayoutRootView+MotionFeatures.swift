extension LayoutRootView {
    /// Feature `paneHoldsContentInMotion`: while a split, close, column or zoom
    /// springs, each pane's content keeps the larger of its starting and final size, clipped, and lays out
    /// once at the landing. Each pane host asks it at its spring's start. False (the default): content resizes
    /// live on every frame.
    public var holdsContentInMotion: () -> Bool {
        get { context.holdsContentInMotion }
        set { context.holdsContentInMotion = newValue }
    }
}
