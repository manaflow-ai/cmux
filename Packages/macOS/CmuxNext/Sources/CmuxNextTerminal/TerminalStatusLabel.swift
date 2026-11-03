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
    /// The label view, nil until a label first shows.
    private(set) var banner: TerminalStatusBanner?
    /// A label that waits out its reveal delay: when the wait started, how long it is, and its task.
    private var waiting: (start: CFTimeInterval, delay: CFTimeInterval, task: Task<Void, Never>)?
    /// The words the label shows when the wait ends (the latest status's).
    private var waitingText: String?
    private let clock: any Clock<Duration>
    /// Adds a newly built label to the host (above the scroller, below the other overlays).
    private let install: (TerminalStatusBanner) -> Void
    /// Called when the label appeared after its wait (the host lays it out).
    private let didReveal: () -> Void

    /// - Parameters:
    ///   - clock: The clock of the reveal delays; tests pass a manual clock.
    ///   - install: Adds the label view to the host the first time a label shows.
    ///   - didReveal: Called when a waiting label appears.
    init(clock: any Clock<Duration>, install: @escaping (TerminalStatusBanner) -> Void, didReveal: @escaping () -> Void) {
        self.clock = clock
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
            guard let banner, !banner.isHidden else { return false }
            banner.hide()
            return true
        }
        if let banner, !banner.isHidden {
            banner.show(text, fadeIn: false)
            return true
        }
        guard let delay = TerminalStatusBanner.revealDelay(for: status, stall: stall) else {
            endWait()
            showNow(text, fadeIn: false)
            return true
        }
        wait(delay, text: text)
        return false
    }

    private func wait(_ delay: CFTimeInterval, text: String) {
        waitingText = text
        let now = CACurrentMediaTime()
        if let pending = waiting, now < pending.start + pending.delay {
            // Still waiting: keep that wait unless this status waits longer from the same start.
            guard delay > pending.delay else { return }
            pending.task.cancel()
            waiting = (pending.start, delay, revealTask(after: pending.start + delay - now))
            return
        }
        waiting?.task.cancel()
        waiting = (now, delay, revealTask(after: delay))
    }

    private func revealTask(after seconds: CFTimeInterval) -> Task<Void, Never> {
        let clock = clock
        // A bounded, cancellable delay that is the intended behavior (a transient status's quiet
        // time); the next status cancels it. Its clock is injected.
        return Task { [weak self] in
            // wakeup-allow: one-shot injected reveal deadline; the next status cancels it.
            do { try await clock.sleep(for: .seconds(max(0, seconds))) } catch { return }
            self?.waitEnded()
        }
    }

    private func waitEnded() {
        guard waiting != nil, let text = waitingText else { return }
        waiting = nil
        waitingText = nil
        showNow(text, fadeIn: true)
        didReveal()
    }

    private func endWait() {
        waiting?.task.cancel()
        waiting = nil
        waitingText = nil
    }

    private func showNow(_ text: String, fadeIn: Bool) {
        if let banner { return banner.show(text, fadeIn: fadeIn) }
        let made = TerminalStatusBanner()
        install(made)
        banner = made
        made.show(text, fadeIn: fadeIn)
    }
}
