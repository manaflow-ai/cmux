public import AppKit
public import CmuxNextDesignTokens
public import CmuxNextWakeups
import Observation
public import SwiftUI

/// Retries a load the person would only ever answer "yes" to (re-fetch, reconnect, reload a view, re-poll) on its
/// own, instead of a "Try again" button. Leo, 2026-11-22: "i dont know what kind of decision a "try again" would be
/// other than "ok i guess ill click this." vacuous decisions like that should be just done and the underlying problems
/// should be done better at the root".
///
/// The owner calls ``failed()`` when an attempt fails and ``succeeded()`` when one works. After a failure the next
/// attempt runs after a capped, jittered ``Backoff``, but only while the view is in sight (``setInSight(_:)``, which
/// ``View/autoRetry(_:)`` drives from appear/disappear and the window's occlusion). Out of sight nothing is armed; back
/// in sight, a failing load runs one attempt at once. Nothing shows at first: ``showsNotice`` turns true only once the
/// failures have lasted ``NoticeTiming/connectionQuiet``, and then the view draws at most one quiet line, no button.
///
/// A retry that costs something or has a side effect the person must choose (a paid request, a side-effecting action,
/// sign-in, an install or update that replaces binaries) keeps its button, marked `retry-prompt-ok: <reason>`.
@MainActor
@Observable
public final class AutoRetry {
    /// The failures have lasted ``NoticeTiming/connectionQuiet``: the view may show one quiet line (never a button).
    public private(set) var showsNotice = false
    /// The last attempt failed and no attempt has worked since.
    public private(set) var isFailing = false
    /// The view is in sight: on screen, in a window that is not fully covered or minimized.
    public private(set) var inSight = true

    @ObservationIgnored private var attempt: @MainActor () -> Void
    @ObservationIgnored private var backoff: Backoff
    @ObservationIgnored private let quiet: Duration
    @ObservationIgnored private let retryTimer: DemandTimer
    @ObservationIgnored private let noticeTimer: DemandTimer

    /// - Parameters:
    ///   - owner: The wakeup ledger's name for this loop's timers.
    ///   - backoff: Spacing between attempts; 1 s growing to 30 s, ±30% by default.
    ///   - quiet: How long failures stay out of sight; the shared connection bound by default.
    ///   - attempt: One attempt; the owner reports its outcome with ``failed()`` or ``succeeded()``.
    public init(owner: String,
                backoff: Backoff = Backoff(initial: .seconds(1), maximum: .seconds(30), jitter: 0.3),
                quiet: Duration = NoticeTiming.connectionQuiet,
                clock: any Clock<Duration> = ContinuousClock(),
                attempt: @escaping @MainActor () -> Void = {}) {
        self.backoff = backoff
        self.quiet = quiet
        self.attempt = attempt
        retryTimer = DemandTimer(owner: "\(owner).retry", clock: clock)
        noticeTimer = DemandTimer(owner: "\(owner).notice", clock: clock)
    }

    /// Replaces the attempt (a view that builds its retry before it has the closure it calls).
    public func setAttempt(_ attempt: @escaping @MainActor () -> Void) {
        self.attempt = attempt
    }

    /// The attempt failed: the next one runs after the backoff while in sight, and the quiet bound starts with the
    /// first failure of a stretch.
    public func failed() {
        if !isFailing {
            isFailing = true
            noticeTimer.schedule(after: quiet) { @MainActor [weak self] in
                guard let self, isFailing else { return }
                showsNotice = true
            }
        }
        armRetry()
    }

    /// The attempt worked (or the view no longer needs it): the stretch ends, the line hides and the spacing starts
    /// over.
    public func succeeded() {
        isFailing = false
        showsNotice = false
        backoff.reset()
        retryTimer.cancel()
        noticeTimer.cancel()
    }

    /// The view came into sight or went out of it. Out of sight: no timer runs. Back in sight while failing: one
    /// attempt at once.
    public func setInSight(_ visible: Bool) {
        guard visible != inSight else { return }
        inSight = visible
        guard visible else {
            retryTimer.cancel()
            return
        }
        guard isFailing else { return }
        retryTimer.cancel()
        attempt()
    }

    /// Stops the loop (the view went away for good); a later ``failed()`` starts it again.
    public func stop() {
        retryTimer.cancel()
        noticeTimer.cancel()
        isFailing = false
        showsNotice = false
    }

    /// True while an attempt is armed.
    public var isScheduled: Bool { retryTimer.isScheduled }

    private func armRetry() {
        guard inSight else { return }
        retryTimer.schedule(after: backoff.next()) { @MainActor [weak self] in
            guard let self, isFailing, inSight else { return }
            attempt()
        }
    }
}

extension View {
    /// Drives `retry`'s sight from this view: appear and disappear, and its window's occlusion and minimizing.
    public func autoRetry(_ retry: AutoRetry) -> some View {
        modifier(AutoRetrySight(retry: retry))
    }
}

private struct AutoRetrySight: ViewModifier {
    let retry: AutoRetry
    @State private var appeared = false
    @State private var windowVisible = true

    func body(content: Content) -> some View {
        content
            .background(AutoRetryWindowSight { windowVisible = $0 })
            .onAppear { appeared = true; retry.setInSight(windowVisible) }
            .onDisappear { appeared = false; retry.setInSight(false) }
            .onChange(of: windowVisible) { _, visible in retry.setInSight(appeared && visible) }
    }
}

/// Reports whether the hosting window is in sight: ordered in, not minimized, not fully covered.
private struct AutoRetryWindowSight: NSViewRepresentable {
    let changed: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> SightView { SightView(changed: changed) }
    func updateNSView(_ view: SightView, context: Context) { view.changed = changed }

    final class SightView: NSView {
        var changed: @MainActor (Bool) -> Void
        private weak var followed: NSWindow?

        init(changed: @escaping @MainActor (Bool) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let followed { FrameScheduler.unfollowSight(of: followed, owner: self) }
            followed = window
            guard let window else { return }
            // The app's one occlusion observer tells this view (minimizing changes occlusion too).
            FrameScheduler.followSight(of: window, owner: self) { [weak self] in self?.report() }
            report()
        }

        private func report() {
            guard let window else { return }
            changed(!FrameScheduler.windowIsOutOfSight(window))
        }
    }
}
