import CmuxSimulator

extension SimulatorPaneCoordinator {
    /// Applies the pane's host visibility to every resource that should stop
    /// work while the Simulator is occluded.
    public func setPaneVisibility(_ isVisible: Bool) {
        paneIsVisible = isVisible
        applyEffectivePaneVisibility()
    }

    func setHostWindowVisibility(_ isVisible: Bool) {
        guard hostWindowIsVisible != isVisible else { return }
        hostWindowIsVisible = isVisible
        applyEffectivePaneVisibility()
    }

    var effectivePaneIsVisible: Bool {
        paneIsVisible && hostWindowIsVisible
    }

    private func applyEffectivePaneVisibility() {
        let isVisible = effectivePaneIsVisible
        setAccessibilityOverlayVisibility(isVisible)
        setLiveStatusVisibility(isVisible && showsTools)
        setFrameVisibility(isVisible)
    }

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
