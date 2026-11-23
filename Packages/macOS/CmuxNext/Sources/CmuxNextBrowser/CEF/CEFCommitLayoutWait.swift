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
    ///   - laidOut: the page's answer; by default a script in the page's isolated world (``pageLaidOut(_:_:)``).
    ///   - frames: the display frames; by default those of the view's window (``windowFrames(_:_:)``).
    init(laidOut: @escaping LaidOut = CEFCommitLayoutWait.pageLaidOut, frames: @escaping Frames = CEFCommitLayoutWait.windowFrames) {
        self.laidOut = laidOut
        self.frames = frames
    }

    /// Runs ``laidOutScript(_:)`` in the page's isolated world. Only on the renderer path (fork API 29): a DevTools
    /// evaluation would open a session (and keep the page's renderer from being shared) for a wait the display frames
    /// bound anyway.
    static func pageLaidOut(_ tab: CEFTab, _ pixels: CGSize) async -> Bool {
        guard tab.runtime.forkFeatures.rendererPaths,
              let value = try? await tab.evaluate(laidOutScript(pixels), world: .isolated, gesture: .cmux) else { return false }
        return value == .bool(true)
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
