import AppKit
import CmuxNextDesign
import CmuxNextWakeups
import GhosttyNextKit
import IOSurface

/// cx-6so.23: a replay swaps in a fresh surface (Ghostty has no reset), and the fresh surface has
/// no frame until its renderer draws one, so a terminal shown again (a tab closed over it, a cold
/// workspace switched back to) showed an empty pane for 2-3 frames. The old surface's last frame
/// stays painted over the fresh one until the fresh one presents the replay. An evicted terminal shown
/// again (a new session), a restored terminal at launch (its frame from the last quit) and a session that
/// replaces another on its tab (the frame it carried) show their frame the same way, until the first content
/// the owner sends is presented, however long the attach takes: a relaunch whose daemon restores hundreds of
/// terminals can answer seconds late, and an empty surface with a cursor box is never better than the last
/// content (Chrome keeps a tab's last frame up until the new content paints). A link that fails and retries says
/// so in the status banner over that frame. The quit saves what the pane shows, so a pane still held saves its
/// held frame, not the empty surface under it (``heldFrame``).
///
/// One rule ends every hold, a content sequence (principled-audit restoreFrameHold R3/R5): a hold's target is
/// the first content queued on the surface's lane from its start (the replay of a swap, an attach's first
/// content). Until that content is parsed the surface does not draw (``TerminalSurfaceView/awaitsContent``,
/// ``SurfacePause/awaitingContent``), so every frame it presents after the parse shows it. The parse's mark on the
/// lane raises ``parsedSeq`` to the target; the first frame presented after that (a presented frame other than the
/// one on screen at the parse) raises ``presentedSeq`` to it. The held frame is on screen iff
/// `presentedSeq < targetSeq`; no timer ends a hold. The session owns it: its close, an exit and a link that will
/// not come back by itself end it (``end()``).
///
/// Every frame it compares is the one the renderer reports presented (``TerminalFrameSource``): the
/// fresh surface's layer is only the container of the renderer's leaf, so its contents say nothing. A swapped-in
/// surface never drew before its replay (``prepare(_:)``); a session's first surface paused at the hold's start, and
/// Ghostty's hide waits for the frames in flight then (`setVisible(false)`), so no frame drawn before the parse
/// presents after it. With renderer-owned frames (`GHOSTTY_RENDERER_FRAMES`) the presented callback's frame id can
/// replace the identity compare.
@MainActor
final class TerminalFrameHold {
    private let view = HeldFrameView()
    /// The frame the view shows while a hold is on screen.
    private var held: HeldFrame?
    private weak var surface: TerminalSurfaceView?
    /// The content sequence (one count per hold, never reset): a hold waits for content number ``targetSeq``.
    private(set) var targetSeq: UInt64 = 0
    /// The newest target whose content the lane parsed into the held surface.
    private(set) var parsedSeq: UInt64 = 0
    /// The newest target whose content the held surface presented.
    private(set) var presentedSeq: UInt64 = 0
    /// The hold waits for its content to be queued on the lane (``contentQueued()``).
    private var awaitingContent = false
    /// The frame on screen when the target's content was parsed: a different one is drawn after it.
    private var frameAtParse: AnyObject?
    /// Where the parsed content's refresh is posted.
    private let mainWork: MainWorkScheduler
    private let parsedOwner: MainTaskOwner
    // Motion rate: the swap must not show a blank frame.
    // frame-client: removes the held view the frame the fresh surface presents its content (AppKit, on main)
    private lazy var frames = FrameClient(owner: "TerminalFrameHold", isAnimation: false, rate: .motion, scheduler: { [weak self] in
        self?.surface.map(FrameScheduler.forView) ?? .app
    }) { [weak self] _ in self?.tick() ?? false }

    /// - Parameter mainWork: The app's main-thread scheduler; the parsed content's refresh runs there.
    init(mainWork: MainWorkScheduler) {
        self.mainWork = mainWork
        parsedOwner = mainWork.board.owner("TerminalFrameHold.parsed")
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

    /// A fresh surface about to take an old one's place (``begin(old:fresh:in:)`` next, in the same turn): it draws
    /// nothing from its first turn in the window, so no frame of it before its content can land after the hold starts.
    func prepare(_ fresh: TerminalSurfaceView) {
        fresh.awaitsContent = true
    }

    /// Paints `old`'s last frame (or the frame this hold already shows) over `fresh` in `host` until `fresh`
    /// presents the content its session queues next on its lane (the replay, ``contentQueued()``).
    func begin(old: TerminalSurfaceView, fresh: TerminalSurfaceView, in host: NSView) {
        // A swap during a hold keeps the held frame: the surface it replaces may only show a blank one.
        let held = heldFrame ?? old.presentedFrame.map(HeldFrame.surface)
        end()
        // Only a swap someone may see holds a frame: a hidden terminal keeps no old frame alive until it shows.
        var inputs = fresh.drawInputs
        inputs.awaitingContent = false
        guard inputs.draws, let held, fresh.lane != nil else {
            fresh.awaitsContent = false // no hold: it draws as any surface does (``prepare(_:)``)
            return
        }
        show(held, over: fresh, like: old.layer, in: host)
    }

    /// Paints `frame` (an evicted terminal's last frame, an IOSurface; or its frame from the last
    /// quit, a CGImage) over `fresh`, a new session's first surface, until the first content
    /// queued on its lane (``contentQueued()``) is parsed and presented.
    func begin(lastFrame frame: HeldFrame, over fresh: TerminalSurfaceView, in host: NSView) {
        end()
        show(frame, over: fresh, like: fresh.layer, in: host)
    }

    /// The session queued content on the surface's lane: a hold waiting for its first content now waits for
    /// that content to be parsed (the lane's mark after it), then presented.
    func contentQueued() {
        guard awaitingContent else { return }
        // A surface with no lane parses nothing: no content will reach it.
        guard let lane = surface?.lane else { return end() }
        awaitingContent = false
        let target = targetSeq
        // Runs after the caller queued the content on the lane: once that is parsed, one `visible` task
        // (the pane shows the held frame meanwhile) lets the surface draw it.
        lane.whenDrained { [weak self, mainWork, parsedOwner] in
            mainWork.postFromAnyThread(.visible, owner: parsedOwner) { self?.parsed(target) }
        }
    }

    private func show(_ held: HeldFrame, over fresh: TerminalSurfaceView, like source: CALayer?, in host: NSView) {
        targetSeq &+= 1
        awaitingContent = true
        surface = fresh
        self.held = held
        view.show(held.contents, like: source, frame: fresh.frame)
        // Above the surface, so above the leaf its renderer presents into (a sublayer of the
        // surface's layer); under the banner, scroller and find bar over it.
        host.addSubview(view, positioned: .above, relativeTo: fresh)
        fresh.awaitsContent = true // it draws nothing until its target's content is parsed
        checkInvariant()
    }

    /// The lane parsed content number `target` into the held surface: it may draw now, and its next presented frame
    /// shows that content.
    private func parsed(_ target: UInt64) {
        guard target == targetSeq, let surface, presentedSeq < target else { return }
        parsedSeq = target
        frameAtParse = surface.presentedFrame
        surface.awaitsContent = false
        // A frame of the parsed state, even if the renderer has nothing else to draw.
        // SAFETY: the held view's live surface (TerminalSurfaceView.surface), on the main actor.
        if let ghostty = surface.surface { unsafe ghostty_surface_refresh(ghostty) }
        frames.activate()
        checkInvariant()
    }

    /// The held surface drew; while it is paused (hidden, its window covered) it presents nothing new, and the
    /// hold stays until it does (``tick()``).
    func surfaceDrawingChanged(_ view: TerminalSurfaceView) {
        guard view === surface, parsedSeq == targetSeq, presentedSeq < targetSeq else { return }
        frames.activate()
    }

    /// Takes the held frame away: the hold is over whether or not its content came (a close, an exit, a link that
    /// will not come back by itself, a newer hold).
    func end() {
        frames.deactivate()
        view.removeFromSuperview()
        view.clear()
        held = nil
        let released = surface
        surface = nil // first: the surface's draw change below finds no hold
        released?.awaitsContent = false
        presentedSeq = targetSeq
        parsedSeq = targetSeq
        frameAtParse = nil
        awaitingContent = false
        checkInvariant()
    }

    /// Once per display frame after the parse: the first frame presented since then is the target's content.
    private func tick() -> Bool {
        guard let surface else {
            end()
            return false
        }
        guard parsedSeq == targetSeq, presentedSeq < targetSeq else { return false }
        guard let shown = surface.presentedFrame, shown !== frameAtParse else { return surface.pause == nil }
        presentedSeq = parsedSeq
        end()
        return false
    }

    /// The R3 invariant (DEBUG `InputInvariantMonitor`; principled-audit restoreFrameHold): the held frame is on
    /// screen iff the surface has not presented the target's content, and a surface that waits for content is
    /// the held one. Nil when it holds; else what differs.
    var invariantViolation: String? {
        let behind = presentedSeq < targetSeq
        if isHolding != behind { return "held frame shown \(isHolding), presented \(presentedSeq) of target \(targetSeq)" }
        if let surface, surface.awaitsContent != (behind && parsedSeq < targetSeq) {
            return "surface awaits content \(surface.awaitsContent), parsed \(parsedSeq) of target \(targetSeq)"
        }
        return nil
    }

    private func checkInvariant() {
        #if DEBUG
        if let violation = invariantViolation { assertionFailure("TerminalFrameHold: \(violation)") }
        #endif
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
