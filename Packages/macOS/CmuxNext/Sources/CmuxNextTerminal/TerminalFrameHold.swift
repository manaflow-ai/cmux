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
/// content is parsed and drawn, however long its attach takes: a relaunch whose daemon restores
/// hundreds of terminals can answer an attach seconds late, and an empty surface with a cursor box
/// is never better than the last content (Chrome keeps a tab's last frame up until the new content
/// paints). A link that fails says so in the status banner over that frame. The quit saves what the pane
/// shows, so a pane still held saves its held frame, not the empty surface under it (``heldFrame``).
///
/// Every frame it compares is the one the renderer reports presented (``TerminalFrameSource``): the
/// fresh surface's layer is only the container of the renderer's leaf, so its contents say nothing.
@MainActor
final class TerminalFrameHold {
    /// The longest the old frame stays once the content it waits for is queued: a surface that
    /// never draws shows as it is after this.
    static let limit: Duration = .milliseconds(500)

    private let view = HeldFrameView()
    /// The frame the view shows while a hold is on screen.
    private var held: HeldFrame?
    private weak var surface: TerminalSurfaceView?
    /// Once the replay is parsed: the fresh surface's frame then, and the ticks seen since. A frame
    /// captured before the parse can still present on the next tick, so only a change seen two
    /// ticks on counts.
    private var parsed: (frame: AnyObject?, ticks: Int)?
    /// A last-frame hold whose surface has no content queued yet: it waits for ``contentQueued()``.
    private var awaitingContent = false
    private var generation = 0
    /// The hold's limit once content is queued (``limit``): a pane shows the held frame until then, so a `visible` task.
    private let deadline: MainDeadline
    /// Where the parsed replay's refresh is posted.
    private let mainWork: MainWorkScheduler
    private let parsedOwner: MainTaskOwner
    // Motion rate: the swap must not show a blank frame.
    // frame-client: removes the held view the frame the fresh surface presents (AppKit, on main)
    private lazy var frames = FrameClient(owner: "TerminalFrameHold", isAnimation: false, rate: .motion, scheduler: { [weak self] in
        self?.surface.map(FrameScheduler.forView) ?? .app
    }) { [weak self] _ in self?.tick() ?? false }

    /// - Parameter deadlines: The app's one `MainDeadline` placer; its scheduler runs the parsed replay's refresh.
    init(deadlines: MainDeadlineScheduler) {
        mainWork = deadlines.work
        parsedOwner = deadlines.work.board.owner("TerminalFrameHold.parsed")
        deadline = MainDeadline(owner: "TerminalFrameHold.limit", workClass: .visible, scheduler: deadlines)
    }

    /// Whether a held frame is on screen.
    var isHolding: Bool { view.superview != nil }

    /// The frame on screen while a hold shows one, as the pane shows it; nil while nothing is held.
    var heldFrame: HeldFrame? { isHolding ? held : nil }

    /// A held frame's pixels: a renderer's presented IOSurface (a surface swapped out, an evicted terminal's last
    /// frame) or a decoded picture (a terminal's frame from the last quit).
    enum HeldFrame {
        case surface(IOSurface)
        case image(CGImage)

        /// The layer contents that show it.
        var contents: Any {
            switch self {
            case .surface(let surface): surface
            case .image(let image): image
            }
        }
    }

    /// Paints `old`'s last frame (or the frame this hold already shows) over `fresh` in `host`
    /// until `fresh` presents a frame drawn after the output queued on its lane so far.
    func begin(old: TerminalSurfaceView, fresh: TerminalSurfaceView, in host: NSView) {
        // A swap during a hold keeps the held frame: the surface it replaces may only show a blank one.
        let held = heldFrame ?? old.presentedFrame.map(HeldFrame.surface)
        end()
        // Only a swap on screen: a reveal unsuspends before its geometry claim brings the replay.
        guard WindowDrawPolicy.inputs(for: fresh, suspended: fresh.isRenderingSuspended).draws,
              let held, fresh.lane != nil else { return }
        show(held, over: fresh, like: old.layer, in: host)
        waitForDraw()
    }

    /// Paints `frame` (an evicted terminal's last frame, an IOSurface; or its frame from the last
    /// quit, a CGImage) over `fresh`, a new session's first surface, until the first content
    /// queued on its lane (``contentQueued()``) is parsed and drawn. No timer ends it before that:
    /// the empty surface under it is never what the pane should show.
    func begin(lastFrame frame: HeldFrame, over fresh: TerminalSurfaceView, in host: NSView) {
        end()
        show(frame, over: fresh, like: fresh.layer, in: host)
        awaitingContent = true
    }

    /// The session queued its first content on the surface's lane: a last-frame hold now waits
    /// for it to be drawn.
    func contentQueued() {
        guard awaitingContent else { return }
        awaitingContent = false
        waitForDraw()
    }

    private func show(_ held: HeldFrame, over fresh: TerminalSurfaceView, like source: CALayer?, in host: NSView) {
        generation &+= 1
        surface = fresh
        self.held = held
        view.show(held.contents, like: source, frame: fresh.frame)
        // Above the surface, so above the leaf its renderer presents into (a sublayer of the
        // surface's layer); under the banner, scroller and find bar over it.
        host.addSubview(view, positioned: .above, relativeTo: fresh)
    }

    private func waitForDraw() {
        guard let lane = surface?.lane else { return end() }
        let generation = generation
        frames.activate()
        deadline.schedule(after: Self.limit) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.end()
        }
        // Runs after the caller queued the content on the lane: once that is parsed, one `visible` task
        // (the pane shows the held frame meanwhile) asks for a frame of the parsed state.
        lane.whenDrained { [weak self, mainWork, parsedOwner] in
            mainWork.postFromAnyThread(.visible, owner: parsedOwner) { self?.replayParsed(generation: generation) }
        }
    }

    private func replayParsed(generation: Int) {
        guard self.generation == generation, let surface else { return }
        parsed = (surface.presentedFrame, 0)
        // A frame from the parsed state, even if the renderer has nothing else to draw.
        // SAFETY: the held view's live surface (TerminalSurfaceView.surface), on the main actor.
        if let ghostty = surface.surface { unsafe ghostty_surface_refresh(ghostty) }
    }

    /// Takes the held frame away.
    func end() {
        frames.deactivate()
        deadline.cancel()
        view.removeFromSuperview()
        view.clear()
        held = nil
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

/// A pane's shown frame handed from a terminal session to the one that replaces it on the same tab
/// (``TerminalSession/carriedFrame()``, ``TerminalSession/holdCarriedFrame(_:)``).
@MainActor
public struct TerminalCarriedFrame {
    let frame: TerminalFrameHold.HeldFrame
}
