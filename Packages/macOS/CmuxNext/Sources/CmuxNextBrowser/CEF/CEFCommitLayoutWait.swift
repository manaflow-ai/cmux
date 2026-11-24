import AppKit
import CmuxNextWakeups

/// How a Chromium page that took its pane's next size ahead of a layout commit (a zoom, the close of a pane beside it)
/// tells that it laid out at that size, on an engine with no resize fence (fork API 33 and older): the page's own
/// animation frames, read by a script, and the display frames of its window, which bound the wait. Chromium shows its
/// GPU output through a `CALayerHost` of the GPU process's context (`DisplayCALayerTree::GotCALayerFrame`), so no
/// layer in this process carries the size of the frame it shows.
///
/// A seam of ``CEFPaneHost``: tests pass their own answers and frames.
struct CEFCommitLayoutWait {
    /// Answers true once `tab`'s page laid out at `pixels` (its viewport in device pixels) and began the frame after
    /// that one, so the frame at the new size went to the GPU; false when it cannot tell.
    typealias LaidOut = @MainActor (_ tab: CEFTab, _ pixels: CGSize) async -> Bool
    /// Calls `tick(false)` once per display frame of `view`'s window until it returns false, or `tick(true)` once when
    /// no frame comes any more (the window closed or went out of sight). Returns the block that stops the ticks.
    typealias Frames = @MainActor (_ view: NSView, _ tick: @escaping @MainActor (_ last: Bool) -> Bool) -> @MainActor () -> Void

    let laidOut: LaidOut
    let frames: Frames

    /// - Parameters:
    ///   - laidOut: the page's answer; by default a script in the page's world (``pageLaidOut(_:_:)``).
    ///   - frames: the display frames; by default those of the view's window (``windowFrames(_:_:)``).
    init(laidOut: @escaping LaidOut = CEFCommitLayoutWait.pageLaidOut, frames: @escaping Frames = CEFCommitLayoutWait.windowFrames) {
        self.laidOut = laidOut
        self.frames = frames
    }

    /// Runs ``laidOutScript(_:)`` in the page's own world, on whichever script path the tab has.
    ///
    /// No shim built from this repository exports the renderer paths (fork API 29: `cmux_shim_tab_evaluate` and the
    /// rest), so the tab evaluates over its DevTools session, which every tab already has for its document scripts, and
    /// which awaits the script's promise. A guard that asked only the renderer path made every wait run to its bound
    /// (pane-perf on cmux20-bench, 2026-11-22: 48 of 48 waits at the bound, `debug.cef` tracker). The page's world,
    /// not an isolated one: over DevTools each isolated evaluation makes a new world (a V8 context) in the page, and
    /// a commit would leave one behind each time; the script only reads the viewport and returns a Boolean, so a page
    /// that lies can only make its own commit show sooner, as with no wait.
    static func pageLaidOut(_ tab: CEFTab, _ pixels: CGSize) async -> Bool {
        do {
            return try await tab.evaluate(laidOutScript(pixels), world: .page, gesture: .cmux) == .bool(true)
        } catch {
            CEFHostView.trackerStats.commitAnswersFailed += 1
            return false
        }
    }

    /// The page's answer: at each animation frame, whether its viewport is `pixels` in device pixels (page zoom aside:
    /// `innerWidth` is in CSS pixels); once it is, it waits one frame more, so the frame laid out at that size went to
    /// the compositor. False after 30 frames at another size.
    nonisolated static func laidOutScript(_ pixels: CGSize) -> String {
        let width = Int(pixels.width.rounded()), height = Int(pixels.height.rounded())
        return """
        (async () => {
          const at = () => Math.abs(innerWidth * devicePixelRatio - \(width)) <= devicePixelRatio + 1
            && Math.abs(innerHeight * devicePixelRatio - \(height)) <= devicePixelRatio + 1;
          const frame = () => new Promise(done => requestAnimationFrame(done));
          for (let i = 0; i < 30 && !at(); i++) await frame();
          if (!at()) return false;
          await frame();
          return true;
        })()
        """
    }

    /// The display frames of `view`'s window, through a ``FrameClient`` that is no animation.
    static func windowFrames(_ view: NSView, _ tick: @escaping @MainActor (_ last: Bool) -> Bool) -> @MainActor () -> Void {
        let client = FrameClient(owner: "cef.commit-layout", isAnimation: false,
                                 scheduler: { [weak view] in view.map(FrameScheduler.forView) ?? .app },
                                 settle: { _ = tick(true) }, dropped: { _ = tick(true) }) { _ in tick(false) }
        client.activate()
        return { client.deactivate() }
    }
}
