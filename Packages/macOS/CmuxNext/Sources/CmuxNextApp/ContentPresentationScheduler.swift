import CmuxNextControl

/// A pane whose selected content the scheduler shows.
@MainActor
protocol PresentablePane: AnyObject {
    /// Showing the selection needs no new surface or page.
    var selectedContentIsAlive: Bool { get }
    /// The pane has its workspace's focus: the person types into it, so its surface comes first.
    var isFocusedInWorkspace: Bool { get }
    func showSelected()
    /// It waits for a later frame: it shows what it has with no new surface (a terminal's last frame from the quit).
    func showWhileWaiting()
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
/// surface is created per frame; the rest wait for the next frame. A
/// waiting pane that has its workspace's focus gets the next frame's surface
/// before the others (REOPEN-F4: the first key typed into a reopened
/// window's focused terminal came before that terminal's surface).
@MainActor
final class ContentPresentationScheduler {
    private let frames: any ControlFrameSource
    private var pending: [ObjectIdentifier: any PresentablePane] = [:]
    private var order: [ObjectIdentifier] = []
    private var isScheduled = false
    /// The frame's one new surface is spent: a surface was made since the last frame, or a show that makes one runs now.
    private var createdThisFrame = false

    init(frames: any ControlFrameSource = FrameBatcher(owner: "ContentPresentation")) {
        self.frames = frames
    }

    /// Queues `pane` to show its selection on the next frame (coalesced).
    func setNeedsShowSelected(_ pane: any PresentablePane) {
        let key = ObjectIdentifier(pane)
        if pending.updateValue(pane, forKey: key) == nil { order.append(key) }
        if !pane.selectedContentIsAlive { pane.showWhileWaiting() }
        schedule()
    }

    /// Shows `pane`'s selection now when that fits this frame's budget (its content is alive, or no surface was made since the
    /// last frame: only a surface really made spends it), else queues it: a split's new pane shows with the layout change.
    @discardableResult
    func showNow(_ pane: any PresentablePane) -> Bool {
        guard present(pane, span: "presentation.showNow") else { setNeedsShowSelected(pane); return false }
        schedule()
        return true
    }

    /// The one way a pane is shown, so `showNow` and the drain share the budget. A show that needs a surface holds it from its
    /// start: its strip's sync can apply the layout, which shows the pane it mounts, before it makes its own surface.
    private func present(_ pane: any PresentablePane, span: String) -> Bool {
        let alive = pane.selectedContentIsAlive
        guard alive || !createdThisFrame else { return false }
        cancel(pane)
        if !alive { createdThisFrame = true }
        BenchSpans.measure(span) { pane.showSelected() }
        if !alive { createdThisFrame = pane.selectedContentIsAlive }
        return true
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
        createdThisFrame = false
        var remaining: [ObjectIdentifier] = []
        // The queue is taken first: a show can queue a pane (a stale strip's sync can apply the layout); it waits behind the panes kept here.
        let queued = order
        order = []
        // The focused pane first; the others keep their order.
        let focused = queued.filter { pending[$0]?.isFocusedInWorkspace == true }
        for key in focused + queued.filter({ !focused.contains($0) }) {
            guard let pane = pending[key] else { continue }
            if !present(pane, span: "presentation.frame") { remaining.append(key) }
        }
        order = remaining + order
        schedule()
    }
}
