import CmuxSimulator

extension SimulatorPaneCoordinator {
    /// Suspends the worker's shared-memory framebuffer when this pane is not visible.
    /// Device control and inspection remain attached and available.
    public func setFrameVisibility(_ isVisible: Bool) {
        guard frameIsVisible != isVisible else { return }
        frameIsVisible = isVisible
        if !isVisible { frameTransport = nil }
        guard status == .streaming else { return }
        enqueue(.setFramebufferPublishing(isVisible))
    }
}
