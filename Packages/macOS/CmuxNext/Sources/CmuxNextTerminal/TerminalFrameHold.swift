import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import GhosttyNextKit
import IOSurface

/// cx-6so.23: a replay swaps in a fresh surface (Ghostty has no reset), and the fresh surface has
/// no frame until its renderer draws one, so a terminal shown again (a tab closed over it, a cold
/// workspace switched back to) showed an empty pane for 2-3 frames. The old surface's last frame
/// stays painted over the fresh one until the fresh one presents a frame drawn after the replay
/// was parsed: the snapshot first, then live. An evicted terminal shown again (a new session) shows
/// its last frame (``TerminalLastFrame``) the same way from its first layout, until its first
/// content is parsed and drawn.
@MainActor
final class TerminalFrameHold {
    /// The longest the old frame stays once the content it waits for is queued: a surface that
    /// never draws shows as it is after this.
    static let limit: Duration = .milliseconds(500)
    /// The longest a last frame waits for its session's first content (a failed or slow attach):
    /// after it, the pane shows the surface as it is.
    static let contentLimit: Duration = .seconds(3)

    private let view = HeldFrameView()
    private weak var surface: TerminalSurfaceView?
    /// Once the replay is parsed: the fresh surface's frame then, and the ticks seen since. A frame
    /// captured before the parse can still present on the next tick, so only a change seen two
    /// ticks on counts.
    private var parsed: (frame: AnyObject?, ticks: Int)?
    /// A last-frame hold whose surface has no content queued yet: it waits for ``contentQueued()``.
    private var awaitingContent = false
    private var generation = 0
    private let deadline = DemandTimer(owner: "TerminalFrameHold.limit")
    private lazy var frames = FrameClient(owner: "TerminalFrameHold", isAnimation: false, scheduler: { [weak self] in
        self?.surface.map(FrameScheduler.forView) ?? .app
    }) { [weak self] _ in self?.tick() ?? false }

    /// Whether a held frame is on screen.
    var isHolding: Bool { view.superview != nil }

    /// Paints `old`'s last frame (or the frame this hold already shows) over `fresh` in `host`
    /// until `fresh` presents a frame drawn after the output queued on its lane so far.
    func begin(old: TerminalSurfaceView, fresh: TerminalSurfaceView, in host: NSView) {
        // A swap during a hold keeps the held frame: the surface it replaces may only show a blank one.
        let held: Any? = (isHolding ? view.shown : nil) ?? old.presentedFrame
        end()
        // Only a swap on screen: a reveal unsuspends before its geometry claim brings the replay.
        guard WindowDrawPolicy.inputs(for: fresh, suspended: fresh.isRenderingSuspended).draws,
              let held, fresh.lane != nil else { return }
        show(held, over: fresh, like: old.layer, in: host)
        waitForDraw()
    }

    /// Paints `frame` (an evicted terminal's last frame, an IOSurface; or its frame from the last
    /// quit, a CGImage) over `fresh`, a new session's first surface, until the first content
    /// queued on its lane (``contentQueued()``) is parsed and drawn.
    func begin(lastFrame frame: Any, over fresh: TerminalSurfaceView, in host: NSView) {
        end()
        show(frame, over: fresh, like: fresh.layer, in: host)
        awaitingContent = true
        let generation = generation
        deadline.schedule(after: Self.contentLimit) { @MainActor [weak self] in
            guard let self, self.generation == generation, self.awaitingContent else { return }
            self.end()
        }
    }

    /// The session queued its first content on the surface's lane: a last-frame hold now waits
    /// for it to be drawn.
    func contentQueued() {
        guard awaitingContent else { return }
        awaitingContent = false
        waitForDraw()
    }

    private func show(_ held: Any, over fresh: TerminalSurfaceView, like source: CALayer?, in host: NSView) {
        generation &+= 1
        surface = fresh
        view.show(held, like: source, frame: fresh.frame)
        // Above the surface, under the banner, scroller and find bar over it.
        host.addSubview(view, positioned: .above, relativeTo: fresh)
    }

    private func waitForDraw() {
        guard let lane = surface?.lane else { return end() }
        let generation = generation
        frames.activate()
        deadline.schedule(after: Self.limit) { @MainActor [weak self] in
            guard let self, self.generation == generation else { return }
            self.end()
        }
        // Runs after the caller queued the content on the lane: it resumes once that is parsed.
        Task { [weak self] in
            await lane.drained()
            guard let self, self.generation == generation, let surface = self.surface else { return }
            self.parsed = (surface.presentedFrame, 0)
            // A frame from the parsed state, even if the renderer has nothing else to draw.
            if let ghostty = surface.surface { ghostty_surface_refresh(ghostty) }
        }
    }

    /// Takes the held frame away.
    func end() {
        frames.deactivate()
        deadline.cancel()
        view.removeFromSuperview()
        view.clear()
        surface = nil
        parsed = nil
        awaitingContent = false
    }

    private func tick() -> Bool {
        guard let surface else {
            end()
            return false
        }
        guard var parsed else { return true }
        parsed.ticks += 1
        self.parsed = parsed
        guard parsed.ticks >= 2, let shown = surface.presentedFrame, shown !== parsed.frame else { return true }
        end()
        return false
    }
}

/// The held frame: it draws over the surface and takes no clicks.
private final class HeldFrameView: NSView {
    private var contents: Any?

    // The layer shows the held frame as it is: AppKit never draws over it.
    nonisolated override var wantsUpdateLayer: Bool { true }

    func show(_ contents: Any, like source: CALayer?, frame: NSRect) {
        self.contents = contents
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.contentsGravity = source?.contentsGravity ?? .topLeft
        layer?.contentsScale = source?.contentsScale ?? 2
        layer?.contents = contents
        self.frame = frame
        autoresizingMask = [.width, .height]
    }

    /// The frame shown, if any.
    var shown: Any? { contents }

    func clear() {
        contents = nil
        layer?.contents = nil
    }

    override func updateLayer() {
        layer?.contents = contents
    }

    // A last frame can be shown before the view is in a window: the frame's pixels are at the
    // window's scale, whatever the source layer had then.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor { layer?.contentsScale = scale }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
