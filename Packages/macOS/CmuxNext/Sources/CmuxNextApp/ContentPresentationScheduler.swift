import CmuxNextDaemonService
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
/// Each queued pane keeps the cause of the changes that queued it (`mainWork.causes`, read when it
/// is queued), and each cause has its own drain on a budgeted `visible` queue of the app's
/// `MainWorkScheduler` (``FrameBatchQueue/enqueue(cause:_:)``). A pane a person's or the
/// frontend's change queued shows in the person's input-response pass or on the next frame,
/// unbudgeted, and takes the frame's surface creation first; the rest yield to pending input and
/// draw on the visible share. A person's drain shows only the person's panes, so it neither waits
/// behind nor pays for the panes automation queued. ``showNow(_:)`` stays synchronous.
@MainActor
final class ContentPresentationScheduler {
    /// A queued pane and the highest cause of the changes that queued it.
    private struct Entry {
        let pane: any PresentablePane
        var cause: ObservationCause
    }

    /// The budgeted `visible` batcher the drains run on, by cause.
    private let frames: FrameBatcher
    /// The next frame of the scheduler, unbudgeted: a person's pane the frame's surface creation
    /// held, and the frame after a creation (so the next creation's frame comes).
    private let nextFrame: FrameBatcher
    private let causes: ObservationCauses
    /// The frame count that tells one frame from the next (``FrameScheduler/frames``).
    private let frameScheduler: FrameScheduler
    private var pending: [ObjectIdentifier: Entry] = [:]
    private var order: [ObjectIdentifier] = []
    /// A person's drain is on order on ``frames``.
    private var personDrainScheduled = false
    /// A person's drain is on order on ``nextFrame``.
    private var nextFrameDrainScheduled = false
    /// A budgeted drain is on order on ``frames``.
    private var budgetedDrainScheduled = false
    /// The frame of the last surface creation, and whether a person's pane made it.
    private var lastCreation: (frame: UInt64, byPerson: Bool)?

    /// - Parameter mainWork: The app's main-thread scheduler: the drains run in its budgeted
    ///   `visible` class (a person's unbudgeted), the causes are its ``MainWorkScheduler/causes``.
    init(mainWork: MainWorkScheduler) {
        frames = FrameBatcher(owner: "ContentPresentation", budgeted: .visible, on: mainWork)
        nextFrame = FrameBatcher(owner: "ContentPresentation.nextFrame", scheduler: mainWork.frames)
        causes = mainWork.causes
        frameScheduler = mainWork.frames
    }

    /// Queues `pane` to show its selection on the next frame (coalesced), with the cause of the
    /// change being made now.
    func setNeedsShowSelected(_ pane: any PresentablePane) {
        let key = ObjectIdentifier(pane)
        var entry = pending[key] ?? Entry(pane: pane, cause: .automation)
        if pending[key] == nil { order.append(key) }
        entry.cause = max(entry.cause, causes.currentCause)
        pending[key] = entry
        schedule(entry.cause)
    }

    /// Shows `pane`'s selection now when that fits this frame's budget (its
    /// content is alive, or this frame may still create a surface), else
    /// queues it. Used when a pane comes on screen, so a split's new pane
    /// draws in the same frame as the layout change instead of one blank
    /// frame later. Returns true when it was shown now.
    @discardableResult
    func showNow(_ pane: any PresentablePane) -> Bool {
        let alive = pane.selectedContentIsAlive, byPerson = Self.isPersons(causes.currentCause)
        guard alive || mayCreate(byPerson: byPerson) else {
            setNeedsShowSelected(pane)
            return false
        }
        cancel(pane)
        if !alive { noteCreation(byPerson: byPerson) }
        BenchSpans.measure("presentation.showNow") { pane.showSelected() }
        return true
    }

    /// Drops a pane that is going away.
    func cancel(_ pane: any PresentablePane) {
        let key = ObjectIdentifier(pane)
        guard pending.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }

    /// Whether a pane of `cause` shows in the unbudgeted, person's drain.
    private static func isPersons(_ cause: ObservationCause) -> Bool { cause >= .frontend }

    /// Puts the drain of `cause`'s lane on order (one a lane at a time). A person's goes to the
    /// input-response pass or the next frame, unbudgeted; the rest to the budgeted `visible` class.
    private func schedule(_ cause: ObservationCause) {
        if Self.isPersons(cause) {
            guard !personDrainScheduled else { return }
            personDrainScheduled = true
            frames.queue.enqueue(cause: cause) { [weak self] in
                guard let self else { return }
                personDrainScheduled = false
                drain(persons: true)
            }
        } else {
            guard !budgetedDrainScheduled else { return }
            budgetedDrainScheduled = true
            frames.queue.enqueue(cause: cause) { [weak self] in
                guard let self else { return }
                budgetedDrainScheduled = false
                drain(persons: false)
            }
        }
    }

    /// A person's drain on the next frame: never in the turn that just created a surface (the
    /// input-response pass runs work queued during it in the same turn).
    private func scheduleNextFrame() {
        guard !nextFrameDrainScheduled else { return }
        nextFrameDrainScheduled = true
        nextFrame.queue.enqueue { [weak self] in
            guard let self else { return }
            nextFrameDrainScheduled = false
            drain(persons: true)
        }
    }

    /// Whether a new surface may be created now: one a frame, except that a person's pane may take
    /// a frame whose creation automation took (the person's never waits behind automation's).
    private func mayCreate(byPerson: Bool) -> Bool {
        guard let lastCreation, lastCreation.frame == frameScheduler.frames else { return true }
        return byPerson && !lastCreation.byPerson
    }

    /// A surface was created now: the frame's creation is spent, and the next frame is asked for.
    private func noteCreation(byPerson: Bool) {
        lastCreation = (frameScheduler.frames, byPerson)
        scheduleNextFrame()
    }

    /// Shows the queued panes of one lane (the person's: a person's or the frontend's cause), in the
    /// order they were queued: content already alive at once, a new surface while ``mayCreate(byPerson:)``.
    /// A pane the frame's creation holds waits for the lane's next drain, on the next frame.
    private func drain(persons: Bool) {
        let queued = order
        order.removeAll(keepingCapacity: true)
        var kept: [ObjectIdentifier] = []
        var held = false
        for key in queued {
            guard let entry = pending[key] else { continue }
            guard Self.isPersons(entry.cause) == persons else {
                kept.append(key)
                continue
            }
            let alive = entry.pane.selectedContentIsAlive
            guard alive || mayCreate(byPerson: persons) else {
                kept.append(key)
                held = true
                continue
            }
            pending[key] = nil
            if !alive { noteCreation(byPerson: persons) }
            BenchSpans.measure("presentation.frame") { entry.pane.showSelected() }
        }
        // A pane a show queued or cancelled meanwhile is already in (or out of) `order`.
        order = kept.filter { pending[$0] != nil } + order
        guard held else { return }
        if persons {
            scheduleNextFrame()
        } else {
            schedule(.program)
        }
    }
}
