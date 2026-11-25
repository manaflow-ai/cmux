import AppKit

/// One wait of a page that took its pane's next size ahead of a layout commit (``CEFTabContentView`` as a
/// `PaneCommitSurface`, on an engine with no resize fence): it reports `ready` once, when the page laid out at the
/// size (``CEFCommitLayoutWait/laidOut``) or at ``readyFrames`` display frames, and asks for `release` at
/// ``releaseFrames`` frames when the page still holds that size then (a commit that never showed).
///
/// The page asks its commit to wait up to ``commitTicks`` frames for it (``PaneCommitSurface/commitWaitTicks``; the
/// commit's own bound, `ScreenContentView.commitBound`, is 3), and the commit shows the pane's ground for a surface
/// that is late. The bound here is one frame under the page's, so the page is never late: a page that has not laid out
/// by then shows its old frame at its top-left corner beside its backdrop, as before this wait.
///
/// ``commitTicks`` stays at the commit's own 3: a page frame at a new size shows about two refreshes after the page's
/// own layout, so a page that lays out in 30 ms shows its frame some 5 to 6 refreshes after the change at 120 Hz, but
/// bench arms of 6 and 8 (pane-perf --film --light-pass, cmux20-bench, 2026-11-22) left gap frames in 4 to 5 of 24
/// films and made each zoom and close of a slow page show 2 to 3 refreshes later. The seam stays for a bound that
/// passes those arms.
final class CEFCommitPageWait {
    /// Frame ticks the page's commit may wait for it.
    static let commitTicks = 3
    /// Display frames until the page is ready whatever it answered: one under ``commitTicks``.
    static let readyFrames = commitTicks - 1
    /// Display frames until a size taken ahead for a commit that has not shown goes (the commit shows at most 4 frames
    /// after its change).
    static let releaseFrames = 8

    private var ready: (@MainActor () -> Void)?
    private var release: (@MainActor () -> Void)?
    private var stopFrames: (@MainActor () -> Void)?
    private var answer: Task<Void, Never>?
    private var frames = 0
    /// In a frame's tick: the tick's own answer stops the frames, not a call back into the frame source.
    private var inFrame = false

    /// Starts the wait now.
    /// - Parameters:
    ///   - tab: the page that took the size.
    ///   - view: a view in the page's window, whose display frames bound the wait.
    ///   - pixels: the page's viewport at the commit's size, in device pixels.
    ///   - wait: how the page answers and the frames come (``CEFPaneHost/commitLayoutWait``).
    ///   - ready: the commit's report; called once, never after ``cancel()``.
    ///   - release: lets the size taken ahead go; called at most once, never after ``holdEnded()`` or ``cancel()``.
    init(tab: CEFTab, view: NSView, pixels: CGSize, using wait: CEFCommitLayoutWait,
         ready: @escaping @MainActor () -> Void, release: @escaping @MainActor () -> Void) {
        self.ready = ready
        self.release = release
        stopFrames = wait.frames(view) { [weak self] last in self?.frame(last: last) ?? false }
        let laidOut = wait.laidOut
        let asked = CEFTrackerStats.now()
        answer = Task { [weak self, weak tab] in
            guard let tab, await laidOut(tab, pixels), let self, !Task.isCancelled else { return }
            guard self.owesReport else {
                // The wait reported at its bound before the page answered: late, not lost.
                CEFHostView.trackerStats.commitAnswersLate += 1
                return
            }
            CEFHostView.trackerStats.commitAnswerSeconds += CEFTrackerStats.now() - asked
            self.report(.answered)
        }
    }

    /// Whether the report is still owed.
    var owesReport: Bool { ready != nil }

    /// The page's hold of the size ended (its commit showed, or the change went): nothing is left to release, and the
    /// frames stop once the report is made.
    func holdEnded() {
        release = nil
        if ready == nil, !inFrame { stop() }
    }

    /// Why a wait reported (`debug.cef` `tracker`: `commit_answered`, `commit_at_bound`, `commit_left`).
    enum Ending {
        /// The page laid out at the size: the wait ended at once.
        case answered
        /// The page had not laid out by ``readyFrames``.
        case atBound
        /// The page hid, left its pane or its window stopped giving frames.
        case left
    }

    /// Reports now, if not yet: by default the page hides or leaves its pane (it draws nothing more for this commit).
    func report(_ ending: Ending = .left) {
        guard let ready else { return }
        self.ready = nil
        switch ending {
        case .answered: CEFHostView.trackerStats.commitWaitsAnswered += 1
        case .atBound: CEFHostView.trackerStats.commitWaitsAtBound += 1
        case .left: CEFHostView.trackerStats.commitWaitsLeft += 1
        }
        if release == nil, !inFrame { stop() }
        ready()
    }

    /// Ends the wait with no report and no release (a later change replaced it).
    func cancel() {
        ready = nil
        release = nil
        answer?.cancel()
        answer = nil
        stop()
    }

    private func frame(last: Bool) -> Bool {
        inFrame = true
        defer { inFrame = false }
        frames += 1
        if last { report(.left) } else if frames >= Self.readyFrames { report(.atBound) }
        if last || frames >= Self.releaseFrames, let release {
            self.release = nil
            release()
        }
        let ticking = ready != nil || release != nil
        if !ticking { stopFrames = nil }
        return ticking
    }

    private func stop() {
        let stop = stopFrames
        stopFrames = nil
        stop?()
    }
}
