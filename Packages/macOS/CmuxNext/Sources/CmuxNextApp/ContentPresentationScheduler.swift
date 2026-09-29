import CmuxNextControl

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
    private var pending: [ObjectIdentifier: PaneController] = [:]
    private var order: [ObjectIdentifier] = []
    private var isScheduled = false

    init(frames: any ControlFrameSource = DisplayLinkFrameScheduler()) {
        self.frames = frames
    }

    /// Queues `pane` to show its selection on the next frame (coalesced).
    func setNeedsShowSelected(_ pane: PaneController) {
        let key = ObjectIdentifier(pane)
        if pending.updateValue(pane, forKey: key) == nil { order.append(key) }
        schedule()
    }

    /// Drops a pane that is going away.
    func cancel(_ pane: PaneController) {
        let key = ObjectIdentifier(pane)
        guard pending.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }

    private func schedule() {
        guard !isScheduled, !pending.isEmpty else { return }
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
                pane.showSelected()
            } else {
                remaining.append(key)
            }
        }
        order = remaining
        schedule()
    }
}
