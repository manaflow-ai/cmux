extension TerminalSurface {
    /// Attaches the model for immediate user input, bypassing restore pacing.
    @MainActor
    public func attachToViewForInputDemand(_ view: any TerminalSurfaceNativeViewing) {
        guard surface == nil else { return }
        if let attachedView, attachedView !== view { return }
        attachedView = view
        releaseHeadlessStartupWindowIfNeeded(for: view)
        guard allowsRuntimeSurfaceCreation(), view.window != nil else { return }
        createSurface(for: view, source: .inputDemand)
    }
}
