import CmuxNextDaemonService
import CmuxNextFocusUI
import CmuxNextWakeups

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
///
/// Its frames are the budgeted visible class of the app's `MainWorkScheduler`: a selection no
/// input of the person's caused yields to pending input and draws on the visible share. One a
/// person's key or click changed runs on that scheduler's frame unbudgeted
/// (``FrameBatcher/scheduleFrame(byPerson:_:)``), and ``showNow(_:)`` stays synchronous.
@MainActor
final class ContentPresentationScheduler {
    private let frames: FrameBatcher
    private let isPersonTurn: @MainActor () -> Bool
    private var pending: [ObjectIdentifier: any PresentablePane] = [:]
    private var order: [ObjectIdentifier] = []
    /// Queued panes a person's input changed: while one waits, the drain is the person's (unbudgeted).
    private var personPending: Set<ObjectIdentifier> = []
    /// The drain on order: whether it is the person's, and its generation. A person's drain
    /// supersedes a budgeted one on order, whose callback then does nothing.
    private var scheduled: (byPerson: Bool, generation: UInt64)?
    private var generation: UInt64 = 0
    /// A surface was created since the last frame; the frame's budget is spent.
    private var createdThisFrame = false

    /// - Parameters:
    ///   - frames: A budgeted visible batcher on the app's `MainWorkScheduler`.
    ///   - isPersonTurn: Whether a person's discrete input is being dispatched now
    ///     (`InputDispatchContext.isDispatchingDiscreteInput`).
    init(frames: FrameBatcher, isPersonTurn: @escaping @MainActor () -> Bool) {
        self.frames = frames
        self.isPersonTurn = isPersonTurn
    }

    /// The app's scheduler: a budgeted visible batcher on `mainWork`, the person's turn read from
    /// `inputDispatch`.
    convenience init(mainWork: MainWorkScheduler, inputDispatch: InputDispatchContext) {
        self.init(frames: FrameBatcher(owner: "ContentPresentation", budgeted: .visible, on: mainWork),
                  isPersonTurn: { [inputDispatch] in inputDispatch.isDispatchingDiscreteInput })
    }

    /// Queues `pane` to show its selection on the next frame (coalesced).
    func setNeedsShowSelected(_ pane: any PresentablePane) {
        let key = ObjectIdentifier(pane)
        if pending.updateValue(pane, forKey: key) == nil { order.append(key) }
        if isPersonTurn() { personPending.insert(key) }
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

    /// Drops a pane that is going away.
    func cancel(_ pane: any PresentablePane) {
        let key = ObjectIdentifier(pane)
        personPending.remove(key)
        guard pending.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }

    /// Puts one drain on order. It is the person's while a pane their input queued waits, or when
    /// it only ends the frame's surface creation (nothing queued, nothing to budget).
    private func schedule() {
        guard !pending.isEmpty || createdThisFrame else { return }
        let byPerson = !personPending.isEmpty || pending.isEmpty
        if let scheduled, scheduled.byPerson || !byPerson { return }
        generation &+= 1
        let current = generation
        scheduled = (byPerson, current)
        frames.scheduleFrame(byPerson: byPerson) { [weak self] in
            guard let self, self.scheduled?.generation == current else { return }
            self.scheduled = nil
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
                personPending.remove(key)
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
