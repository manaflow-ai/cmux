import CmuxNextControl

/// A pane whose selected content the scheduler shows.
@MainActor
protocol PresentablePane: AnyObject {
    /// Showing the selection needs no new surface or page.
    var selectedContentIsAlive: Bool { get }
    func showSelected()
}

/// Shows panes' selected content on display frames instead of inside model
/// updates (architecture.md 5a).
///
/// A burst of daemon deltas or CLI commands (a storm of new-tab / close)
/// changes a pane's selection many times per frame; creating a Ghostty
/// surface for each transient selection stalled the main thread for
/// 100-180 ms under load (surface creation compiles Metal pipelines
/// synchronously). Here only the selection a pane has at frame time is
/// shown, content already alive is shown at once, and at most one new
/// surface is created per frame; the rest wait for the next frame.
@MainActor
final class ContentPresentationScheduler {
    private let frames: any ControlFrameSource
    private var pending: [ObjectIdentifier: any PresentablePane] = [:]
    private var order: [ObjectIdentifier] = []
    private var isScheduled = false
    /// A surface was created since the last frame; the frame's budget is spent.
    private var createdThisFrame = false

    init(frames: any ControlFrameSource = FrameBatcher(owner: "ContentPresentation")) {
        self.frames = frames
    }

    /// Queues `pane` to show its selection on the next frame (coalesced).
    func setNeedsShowSelected(_ pane: any PresentablePane) {
        let key = ObjectIdentifier(pane)
        if pending.updateValue(pane, forKey: key) == nil { order.append(key) }
        schedule()
    }

    /// Shows `pane`'s selection now when that fits this frame's budget (its
    /// content is alive, or no surface was created since the last frame),
    /// else queues it. Used when a pane comes on screen, so a split's new
    /// pane draws in the same frame as the layout change instead of one
    /// blank frame later. Returns true when it was shown now.
    @discardableResult
    func showNow(_ pane: any PresentablePane) -> Bool {
        let alive = pane.selectedContentIsAlive
        guard alive || !createdThisFrame else {
            setNeedsShowSelected(pane)
            return false
        }
        cancel(pane)
        if !alive { createdThisFrame = true }
        BenchSpans.measure("presentation.showNow") { pane.showSelected() }
        schedule()
        return true
    }

    /// A selection change in `pane` (a tab click, Ctrl-Tab): content that is
    /// already alive swaps in now, in the same frame as the strip's
    /// highlight; content that needs a new surface waits for the frame, so a
    /// burst of selections creates one only for the tab selected by then.
    func showSelection(_ pane: any PresentablePane) {
        if pane.selectedContentIsAlive {
            showNow(pane)
        } else {
            setNeedsShowSelected(pane)
        }
    }

    /// Drops a pane that is going away.
    func cancel(_ pane: any PresentablePane) {
        let key = ObjectIdentifier(pane)
        guard pending.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }

    private func schedule() {
        guard !isScheduled, !pending.isEmpty || createdThisFrame else { return }
        isScheduled = true
        frames.scheduleFrame { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            self.drain()
        }
    }

    private func drain() {
        var created = false
        var remaining: [ObjectIdentifier] = []
        for key in order {
            guard let pane = pending[key] else { continue }
            if pane.selectedContentIsAlive || !created {
                if !pane.selectedContentIsAlive { created = true }
                pending[key] = nil
                BenchSpans.measure("presentation.frame") { pane.showSelected() }
            } else {
                remaining.append(key)
            }
        }
        order = remaining
        createdThisFrame = created
        schedule()
    }
}
