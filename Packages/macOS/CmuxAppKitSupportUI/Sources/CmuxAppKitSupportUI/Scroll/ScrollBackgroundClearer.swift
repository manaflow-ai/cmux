public import AppKit

/// Invisible native helper that clears its enclosing scroll-view background.
@MainActor
public final class ScrollBackgroundClearer: NSView {
    private var resolutionTask: Task<Void, Never>?

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        scheduleResolution()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleResolution()
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func scheduleResolution() {
        resolutionTask?.cancel()
        resolutionTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, let scrollView = enclosingScrollView else { return }
            ClearScrollBackground.apply(to: scrollView)
        }
    }

    deinit {
        resolutionTask?.cancel()
    }
}
