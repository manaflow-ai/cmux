import AppKit

/// When a terminal shows its status label (``TerminalStatusBanner``), and the label view itself,
/// built the first time a label shows.
///
/// A new terminal view (a new tab, a split, a reopen, a workspace switch that makes its terminals
/// again) gets "connected" at once, or "Restoring…" until its first replay. Neither builds or
/// unhides a view: "Restoring…" and "Reconnecting…" wait out their reveal delay
/// (``TerminalStatusBanner/revealDelay(for:stall:)``) with no view at all, and show only if they
/// last. An unhide makes AppKit walk the window's views for cursor rects; with a hidden label held
/// at opacity 0 during the wait, that walk cost 12.5 ms of main thread a HEAVY workspace switch
/// (12 new terminals, STATUS 8158) for labels that never appeared.
@MainActor
final class TerminalStatusLabel {
    /// The label view, nil until a label first shows (or a button above it needs its place).
    private(set) var banner: TerminalStatusBanner?
    /// A label that waits out its reveal delay: when the wait started and how long it is (on
    /// ``clock``, from the label's start), its task, and the task's number (a woken task of an
    /// earlier wait shows nothing).
    private var waiting: (start: Duration, delay: Duration, task: Task<Void, Never>, generation: Int)?
    private var generation = 0
    /// The words the label shows when the wait ends (the latest status's).
    private var waitingText: String?
    /// A status that says more when it lasts (a pane still starting: other words and Close after
    /// ``TerminalStatusBanner/overdueDelay(for:stall:)``): when it began (on ``clock``), how long until
    /// it says more, those words, and the task of that deadline with its number. The task is armed
    /// only while the label shows, so a status that clears within its reveal delay costs no second timer.
    private var lasting: Lasting?
    /// Whether the label shows a lasting status's later words.
    private(set) var isOverdue = false
    /// Close in the label of a pane that still starts was pressed; with none set, no Close is offered.
    var onClose: (@MainActor () -> Void)?
    private let clock: RevealClock
    /// Adds a newly built label to the host.
    private let install: (TerminalStatusBanner) -> Void
    /// Called when the label appeared after its wait (the host lays it out).
    private let didReveal: () -> Void

    /// - Parameters:
    ///   - clock: The clock of the reveal delays; tests pass a manual clock.
    ///   - install: Adds the label view to the host the first time it is built.
    ///   - didReveal: Called when a waiting label appears.
    init(clock: any Clock<Duration>, install: @escaping (TerminalStatusBanner) -> Void, didReveal: @escaping () -> Void) {
        self.clock = RevealClock(clock)
        self.install = install
        self.didReveal = didReveal
    }

    /// The words on screen, nil while no label shows (also while one waits out its delay).
    var shownText: String? {
        guard let banner, !banner.isHidden else { return nil }
        return banner.accessibilityLabel()
    }

    /// Whether a label waits out its reveal delay (diagnostics and tests).
    var isWaiting: Bool { waiting != nil }

    /// The title of the Close on screen, nil while the label offers none.
    var closeTitle: String? { banner?.shownCloseTitle }

    /// Presses the offered Close as a click on it does; false while none is offered (tests).
    func pressClose() -> Bool { banner?.pressClose() ?? false }

    /// Shows the label for `status` (with the host loss, its cause and the daemon's stall), hides it,
    /// or waits. A label on screen stays (with the new words); a hidden one waits its status's delay
    /// first. A change while it still waits keeps the longer wait from the same start, so
    /// "Restoring…" turning into a reconnecting stall does not show early. Returns whether the
    /// label's view changed (the host lays it out).
    @discardableResult
    func show(_ status: TerminalConnectionStatus, hostLoss: TerminalHostLoss?, cause: TerminalHostLossCause?,
              stall: TerminalShellStall?) -> Bool {
        guard let text = TerminalStatusBanner.text(for: status, hostLoss: hostLoss, cause: cause, stall: stall) else {
            endWait()
            endLasting()
            guard let banner, !banner.isHidden else { return false }
            banner.hide()
            return true
        }
        // A status that lasted past its deadline says its later words at once, on screen or not.
        if let later = overdueText(status, stall: stall) {
            endWait()
            showNow(later, inBetween: false, fadeIn: false, closes: true)
            return true
        }
        let inBetween = TerminalStatusBanner.isInBetween(status, stall: stall)
        if let banner, !banner.isHidden {
            banner.show(text, inBetween: inBetween, fadeIn: false)
            armOverdue()
            return true
        }
        guard let delay = TerminalStatusBanner.revealDelay(for: status, stall: stall) else {
            endWait()
            showNow(text, inBetween: inBetween, fadeIn: false)
            armOverdue()
            return true
        }
        wait(.seconds(delay), text: text)
        // A label view built for a button above it takes the words now, still hidden, so its place does not move.
        banner?.setText(text, inBetween: inBetween)
        return false
    }

    /// Builds the hidden label view now: Restart and Retry sit above where it shows, so their
    /// place does not move when a label still waiting appears.
    func prepareView() {
        guard banner == nil else { return }
        let made = TerminalStatusBanner()
        made.onClose = { [weak self] in self?.onClose?() }
        install(made)
        banner = made
        if let waitingText { made.setText(waitingText, inBetween: true) }
    }

    private func wait(_ delay: Duration, text: String) {
        waitingText = text
        let now = clock.elapsed()
        // The deadline passed and its task has not run yet: the label shows now.
        if let pending = waiting, now >= pending.start + pending.delay { return waitEnded(pending.generation) }
        if let pending = waiting, now < pending.start + pending.delay {
            // Still waiting: keep that wait unless this status waits longer from the same start.
            guard delay > pending.delay else { return }
            pending.task.cancel()
            waiting = revealing(start: pending.start, delay: delay)
            return
        }
        waiting?.task.cancel()
        waiting = revealing(start: now, delay: delay)
    }

    private func revealing(start: Duration, delay: Duration) -> (start: Duration, delay: Duration, task: Task<Void, Never>, generation: Int) {
        generation &+= 1
        let generation = generation
        let clock = clock
        // A bounded, cancellable delay that is the intended behavior (a transient status's quiet
        // time); the next status cancels it. Its clock is injected.
        let task = Task { [weak self] in
            // wakeup-allow: one-shot injected reveal deadline; the next status cancels it.
            do { try await clock.wake(start + delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.waitEnded(generation)
        }
        return (start, delay, task, generation)
    }

    private func waitEnded(_ ended: Int) {
        guard let pending = waiting, pending.generation == ended, let text = waitingText else { return }
        waiting = nil
        waitingText = nil
        showNow(text, inBetween: true, fadeIn: true)
        armOverdue()
        didReveal()
    }

    private func endWait() {
        waiting?.task.cancel()
        waiting = nil
        waitingText = nil
    }

    /// Notes when a status that says more later began. Returns its later words once its deadline
    /// has passed, nil before; any other status ends it.
    private func overdueText(_ status: TerminalConnectionStatus, stall: TerminalShellStall?) -> String? {
        guard let delay = TerminalStatusBanner.overdueDelay(for: status, stall: stall),
              let text = TerminalStatusBanner.overdueText(for: status, stall: stall) else {
            endLasting()
            return nil
        }
        let now = clock.elapsed()
        var pending = lasting ?? Lasting(start: now, delay: .seconds(delay), text: text)
        pending.text = text
        let late = isOverdue || now >= pending.start + pending.delay
        if late {
            pending.task?.cancel()
            pending.task = nil
            isOverdue = true
        }
        lasting = pending
        return late ? text : nil
    }

    /// Arms the deadline of the lasting status the label shows (one task; nothing when armed, past or none).
    private func armOverdue() {
        guard var pending = lasting, pending.task == nil, !isOverdue else { return }
        generation &+= 1
        let generation = generation
        let clock = clock
        let deadline = pending.start + pending.delay
        pending.generation = generation
        // A bounded, cancellable delay that is the intended behavior (when a pane that still starts
        // says so); the next other status cancels it. Its clock is injected.
        pending.task = Task { [weak self] in
            // wakeup-allow: one-shot injected deadline of a lasting status; the next other status cancels it.
            do { try await clock.wake(deadline) } catch { return }
            guard !Task.isCancelled else { return }
            self?.overdueReached(generation)
        }
        lasting = pending
    }

    private func overdueReached(_ reached: Int) {
        guard let pending = lasting, pending.generation == reached, !isOverdue else { return }
        lasting?.task = nil
        isOverdue = true
        endWait()
        showNow(pending.text, inBetween: false, fadeIn: false, closes: true)
        didReveal()
    }

    private func endLasting() {
        lasting?.task?.cancel()
        lasting = nil
        isOverdue = false
    }

    private func showNow(_ text: String, inBetween: Bool, fadeIn: Bool, closes: Bool = false) {
        prepareView()
        banner?.show(text, inBetween: inBetween, fadeIn: fadeIn, closes: closes && onClose != nil)
    }
}

/// A status that says more when it lasts (``TerminalStatusLabel``).
private struct Lasting {
    /// When the status began, on the label's clock.
    let start: Duration
    /// How long after `start` it says more.
    let delay: Duration
    /// Its later words (the latest status's).
    var text: String
    /// The task of its deadline, nil while not armed.
    var task: Task<Void, Never>?
    /// That task's number (a woken task of an earlier one shows nothing).
    var generation = 0
}

/// The label's injected clock as offsets from the label's start, so a wait's start and its end are
/// read on the same clock (a manual clock in tests).
private struct RevealClock: Sendable {
    /// The time since the label started.
    let elapsed: @Sendable () -> Duration
    /// Returns when the clock reaches `offset` after the label's start; throws when cancelled.
    let wake: @Sendable (Duration) async throws -> Void

    init<C: Clock<Duration>>(_ clock: C) {
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
        // wakeup-allow: one-shot injected reveal deadline; the label's next status cancels it.
        wake = { offset in try await clock.sleep(until: start.advanced(by: offset), tolerance: nil) }
    }
}
