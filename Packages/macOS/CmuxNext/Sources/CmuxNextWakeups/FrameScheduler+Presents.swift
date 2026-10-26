import CmuxNextSignposts

/// The scheduler that keeps its display clock's link up for ``FramePresentEstimate`` (p09-observability 037).
extension FrameScheduler {
    /// The window-less scheduler on `displays`, which also ticks `displays`'s link for its waiting
    /// presents (``servesPresents()``).
    static func makeApp(displays: DisplayClock) -> FrameScheduler {
        let scheduler = FrameScheduler(name: "app", host: .screen, displays: displays, budget: nil)
        scheduler.servesPresents()
        return scheduler
    }

    /// Makes this scheduler the one that ticks its display clock's link while a recorded key flow's
    /// commit waits for its present (``FramePresentEstimate/onNeedsFrame``): an idle link then runs
    /// until that vsync, or ``FramePresentEstimate/framesToWait`` frames, and stops again. Nothing asks
    /// for frames while no recording turns the frame category on.
    func servesPresents() {
        let presents = displayClock.presents
        presentsClient = FrameClient(owner: "FramePresentEstimate", isAnimation: false, on: self) { [weak presents] _ in
            presents?.frameWaited() ?? false
        }
        presents.onNeedsFrame = { [weak self] in self?.presentsClient?.activate() }
    }
}
