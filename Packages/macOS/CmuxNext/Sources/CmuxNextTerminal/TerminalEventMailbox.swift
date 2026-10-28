import CmuxNextCompat
import CmuxNextTerminalGeometry

/// What one session's events loop and output lane changed for the main actor since its last pass:
/// the announced grid, the connection status, the "Sized for" chip, an exit, queued content and the
/// restore counters, latest wins per field (p03-rendering-085).
///
/// The loop never waits for main: it posts here and goes on with the next event, and the first post
/// after a pass asks for one main turn (``deliver``), which the session runs on its frame through the
/// main-work scheduler's visible queue (a ``FrameBatchQueue``). However many statuses, grids or chips
/// a busy terminal sends, the main actor applies them at most once per frame. Chrome coalesces the
/// same way: `Browser::ScheduleUIUpdate` (chrome/browser/ui/browser.cc) keeps one pending change set
/// per tab and applies it on a timer, and Blink's `MainThreadEventQueue`
/// (third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc) coalesces continuous
/// events to the next frame while a discrete one first flushes what waits: the session's surface swap
/// takes the mailbox first (``TerminalSession/applyEvents()``).
///
/// ```swift
/// mailbox.post { $0.status = .connected }   // from the events loop
/// if let pending = mailbox.take() { apply(pending) }   // on main
/// ```
nonisolated final class TerminalEventMailbox: Sendable {
    /// The changes waiting for the main actor.
    nonisolated struct Pending: Sendable, Equatable {
        /// The latest `.resize` grid (or a local-history READY's).
        var grid: TerminalGridSize?
        var status: TerminalConnectionStatus?
        /// The latest chip; `.some(nil)` clears it. A status other than connected clears it too.
        var sizedFor: TerminalSizedFor??
        /// The process exited after the last status.
        var exited = false
        /// Content was queued on the surface's lane (a replay, a READY, the first output).
        var contentQueued = false
        var readyRestores = 0
        var localSnapshots = 0
        var localHistoryMismatches = 0
        var skippedImages = 0

        var isEmpty: Bool { self == Pending() }

        /// A new status: a later `.exited` is still an exit; one before it is the status's to say.
        /// A view that is not connected no longer knows who sets the grid, so a chip before it goes.
        mutating func set(_ status: TerminalConnectionStatus) {
            self.status = status
            exited = false
            if status != .connected { sizedFor = .some(nil) }
        }

        /// A new chip. Applied one by one, a chip shows only while the view is connected, so a chip
        /// after a pending status that is not connected is cleared: a later `.connected` does not
        /// show it again. With no pending status, the main actor checks the view's connection.
        mutating func setSizedFor(_ chip: TerminalSizedFor?) {
            if let status, status != .connected {
                sizedFor = .some(nil)
            } else {
                sizedFor = .some(chip)
            }
        }
    }

    private nonisolated struct State {
        var pending = Pending()
        /// A main turn was asked for and has not taken the pending changes yet.
        var scheduled = false
    }

    // Lock carve-out (skills/cmux-architecture/references/concurrency-carveouts.md): a short,
    // non-blocking take-and-set between the events loop, the lane's restore callbacks and the main
    // turn; nothing waits under it and nothing is called while it is held.
    private let state = Mutex(State())
    /// Asks for one main turn that takes the changes (from any thread).
    private let deliver: @Sendable () -> Void
    private let deliveryCount = Atomic<Int>(0)

    /// - Parameter deliver: Asks for one main turn that calls ``take()``; called from the posting thread.
    init(deliver: @escaping @Sendable () -> Void) {
        self.deliver = deliver
    }

    /// Main turns asked for so far (each one applies every change posted before it).
    var deliveries: Int { deliveryCount.load(ordering: .relaxed) }

    /// Records a change; asks for a main turn when none is pending.
    func post(_ change: (inout Pending) -> Void) {
        let schedule = state.withLock { state -> Bool in
            change(&state.pending)
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        guard schedule else { return }
        _ = deliveryCount.add(1, ordering: .relaxed)
        deliver()
    }

    /// The changes since the last take, nil when there are none; the next post asks for a new turn.
    func take() -> Pending? {
        state.withLock { state -> Pending? in
            state.scheduled = false
            guard !state.pending.isEmpty else { return nil }
            defer { state.pending = Pending() }
            return state.pending
        }
    }
}
