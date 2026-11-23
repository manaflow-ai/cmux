import AppKit

/// One wait of a page that took its pane's next size ahead of a layout commit (``CEFTabContentView`` as a
/// `PaneCommitSurface`, on an engine with no resize fence): it reports `ready` once, when the page laid out at the
/// size (``CEFCommitLayoutWait/laidOut``) or at ``readyFrames`` display frames, and asks for `release` at
/// ``releaseFrames`` frames when the page still holds that size then (a commit that never showed).
///
/// The commit waits for the report at most 3 frames (`ScreenContentView.commitBound`) and shows the pane's ground for a
/// surface that is late. The bound here is one frame under it, so the page is never late: a page that has not laid out
/// by then shows its old frame at its top-left corner beside its backdrop, as before this wait.
final class CEFCommitPageWait {
    /// Display frames until the page is ready whatever it answered: one under the commit's bound of 3.
    static let readyFrames = 2
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
        answer = Task { [weak self, weak tab] in
            guard let tab, await laidOut(tab, pixels) else { return }
            self?.report()
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

    /// Reports now, if not yet (the page hides or leaves its pane: it draws nothing more for this commit).
    func report() {
        guard let ready else { return }
        self.ready = nil
        answer?.cancel()
        answer = nil
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
        if last || frames >= Self.readyFrames { report() }
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
