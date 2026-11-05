import AppKit
import CmuxNextDesign
import GhosttyNextKit

/// A terminal's size request while its window's commit owns its frame (``TerminalSurfaceView/place(_:anchor:)``).
struct TerminalFrameOwnership {
    /// Ghostty leaves new host sizes to cmux (`ghostty_surface_set_host_present` EMBEDDER): set when the surface is
    /// made, for its whole life (cmux-ad m19: the window's commit owns every terminal frame; no switch).
    var embedderPresents = false
    /// The frame the host wants now.
    var wanted: CGRect?
    /// The edge a kept frame rides while the host's area moves.
    var anchor: PaneMotionAnchor = .top
    /// The size asked of Ghostty and not shown yet (one at a time).
    var inFlight: CGSize?
    /// The view takes the size Ghostty already has: no new size goes to Ghostty, and the cursor box follows after the
    /// Core Animation lock (``TerminalSurfaceView/frameDidLand()``).
    var landing = false
    /// The display scale the layer takes with the frame drawn at it (its window moved to a display of another scale,
    /// ``TerminalSurfaceView/holdsScale(_:)``); until then the layer keeps the scale of the frame it shows.
    var scale: CGFloat?
    /// Draw ahead (cmux-ad m18 and m26): the size its pane's spring gives it at the next refresh, asked of Ghostty after
    /// this refresh's commit (render only: no grid report), so the renderer draws it during the refresh and the next pass
    /// presents it with its bounds. Nil when nothing is drawn ahead.
    var ahead: CGSize?
    /// The draw-ahead size the presenter gives Ghostty after this turn's pass (``TerminalFramePresenter/drawAhead(_:)``).
    var pendingAhead: CGSize?
}

/// FRAME OWNER REFACTOR S4, cmux-ad m18, m19 (no switch) and m26 (draw ahead): a terminal's bounds change only in the
/// commit that presents a frame drawn at those bounds (``TerminalFramePresenter``). Until that frame is drawn the view keeps
/// its last bounds and frame on the anchor edge, clipped where its pane is smaller and beside the terminal's background
/// where it is larger. In a spring the frame of the next refresh's size is asked one refresh ahead, so it is drawn when that
/// refresh's commit comes. This is Chromium's model: the browser compositor shows a new size only with a frame the
/// renderer submitted for it, and the renderer gets the size before it is needed.
extension TerminalSurfaceView {
    /// Places the surface at `frame` in its host. A new size goes to Ghostty, or is the size drawn ahead for this
    /// refresh, and the view keeps its size, its old frame on the `anchor` edge of `frame`, until its window's commit
    /// shows the frame drawn at the new size with the new bounds. One size waits at a time; the newest goes next.
    func place(_ frame: CGRect, anchor: PaneMotionAnchor) { // perf-hot: 1ms motion-frame (each frame of a key resize)
        guard frameOwnership.embedderPresents, isShown, window != nil, surface != nil else {
            // A size or a scale that waits gives way: the view takes this frame now (hidden, parked, no window).
            if frameOwnership.inFlight != nil || frameOwnership.scale != nil || frameOwnership.ahead != nil {
                framePresenter?.cancel(self)
                frameOwnership.inFlight = nil
                frameOwnership.ahead = nil
                frameOwnership.pendingAhead = nil
                applyHeldScale()
            }
            if self.frame != frame { self.frame = frame }
            return
        }
        frameOwnership.wanted = frame
        frameOwnership.anchor = anchor
        guard frameOwnership.inFlight == nil else { return keepOrigin() }
        guard frame.size != bounds.size else {
            if self.frame != frame { self.frame = frame }
            return
        }
        // The size its spring gave it at the last refresh: Ghostty has drawn it, or draws it now.
        if let ahead = frameOwnership.ahead {
            frameOwnership.ahead = nil
            if ahead == frame.size, let presenter = framePresenter {
                frameOwnership.inFlight = ahead
                keepOrigin()
                presenter.request(self)
                return
            }
        }
        let state = hostFrame(present: false)
        guard state != GHOSTTY_HOST_FRAME_NONE, state != GHOSTTY_HOST_FRAME_HIDDEN else {
            // Nothing shown, or nothing drawn while hidden: nothing to keep; the frame that comes fits these bounds.
            self.frame = frame
            if state == GHOSTTY_HOST_FRAME_NONE { framePresenter?.watch(self) }
            return
        }
        requestWantedFrame()
    }

    /// Asks Ghostty for a frame at the wanted size, keeps the view's size and waits for its window's commit.
    func requestWantedFrame() { // perf-hot: 1ms motion-frame (each frame of a key resize)
        guard frameOwnership.embedderPresents, let wanted = frameOwnership.wanted else { return }
        guard isShown, let presenter = framePresenter else {
            // Not shown (or no window): nothing to keep; the view takes the size and the scale it wants now.
            applyHeldScale()
            if frame != wanted { frame = wanted }
            return
        }
        guard wanted.size != bounds.size else {
            if frame != wanted { frame = wanted }
            return
        }
        frameOwnership.ahead = nil
        frameOwnership.inFlight = wanted.size
        // `ghostty_surface_set_size` at the asked size, and the grid report as for any new size.
        updateSurfaceSize()
        keepOrigin()
        presenter.request(self)
    }

    /// Its pane's spring gives this view `size` at the next refresh (``TerminalHostView`` `drawAhead(nextHostSize:)`): the
    /// size goes to Ghostty after this turn's pass, so the renderer draws it during the refresh. Hidden or parked: nothing.
    func drawAhead(_ size: CGSize) { // perf-hot: 1ms motion-frame (each frame of a key resize)
        guard frameOwnership.embedderPresents, isShown, let presenter = framePresenter, size.width >= 1, size.height >= 1,
              size != (frameOwnership.wanted?.size ?? bounds.size) else { return }
        frameOwnership.pendingAhead = size
        presenter.drawAhead(self)
    }

    /// After this turn's pass (``TerminalFramePresenter``): the draw-ahead size goes to Ghostty, render only (its reflow
    /// preview re-wraps the text at it; the PTY's grid follows through the coalescer when the size shows). Not while a size
    /// still waits for its frame: the newer size would drop it, and the next refresh asks for its own size then.
    func applyAhead() { // perf-hot: 1ms motion-frame (each frame of a key resize, after the pass)
        // RED CONTROL (never merge): no draw ahead.
        frameOwnership.pendingAhead = nil
        return
        guard let size = frameOwnership.pendingAhead else { return }
        frameOwnership.pendingAhead = nil
        guard let surface, isShown, frameOwnership.inFlight == nil, size != bounds.size,
              size != frameOwnership.wanted?.size else { return }
        let pixels = convertToBacking(size)
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        frameOwnership.ahead = size
        setSurfacePixels(pixels, on: surface)
        updateReflowPreview()
    }

    /// A size drawn ahead that no layout took (its spring ended or moved elsewhere): Ghostty goes back to the view's size.
    func dropAhead() {
        guard frameOwnership.ahead != nil else { return }
        frameOwnership.ahead = nil
        updateSurfaceSize()
    }

    /// Inside the commit: the view takes the size Ghostty's shown frame has, on the anchor edge of the wanted frame,
    /// and its layer the same geometry (a held display scale included) in this commit. Returns whether it wants
    /// another size since.
    func landRequestedFrame() -> Bool { // perf-hot: 1ms motion-frame (each frame of a key resize, under the CA lock)
        applyHeldScale()
        guard let size = frameOwnership.inFlight, let wanted = frameOwnership.wanted else { return false }
        frameOwnership.inFlight = nil
        let target = Self.anchoredFrame(size: size, in: wanted, anchor: frameOwnership.anchor)
        frameOwnership.landing = true
        frame = target
        frameOwnership.landing = false
        // AppKit may sync a layer's geometry at its next display cycle; this commit is past it.
        layer?.frame = target
        return size != wanted.size
    }

    /// `ghostty_surface_host_frame`: what Ghostty can show for the size it was asked; with `present`, a drawn frame
    /// becomes the layer's contents in the open transaction.
    func hostFrame(present: Bool) -> ghostty_host_frame_e {
        guard let surface else { return GHOSTTY_HOST_FRAME_NONE }
        return ghostty_surface_host_frame(surface, present)
    }

    /// The commit that changed the shown size is done: frames at that size go to the screen off the main thread again.
    func hostFrameCommitted() {
        guard let surface, frameOwnership.embedderPresents else { return }
        ghostty_surface_host_frame_committed(surface)
    }

    /// A window change: a size that waits takes its bounds now, through the usual path, and a held scale goes to the
    /// layer.
    func releaseFrameOwnership() {
        guard frameOwnership.embedderPresents else { return }
        framePresenter?.cancel(self)
        applyHeldScale()
        frameOwnership.ahead = nil
        frameOwnership.pendingAhead = nil
        guard frameOwnership.inFlight != nil, let wanted = frameOwnership.wanted else { return }
        frameOwnership.inFlight = nil
        if frame != wanted { frame = wanted }
    }

    /// A new display scale `backing` while its window's commit owns this terminal's frame, and its layer shows a
    /// frame: the layer keeps the scale of that frame and takes `backing` in the commit that shows the frame drawn at
    /// it (``landRequestedFrame()``), so no commit shows a frame at another scale than its own. Returns whether it
    /// holds the scale; if not, the caller gives it to the layer now (nothing shown or hidden: the next frame fits it).
    func holdsScale(_ backing: CGFloat) -> Bool {
        guard frameOwnership.embedderPresents, isShown, let layer, layer.contentsScale != backing else {
            frameOwnership.scale = nil
            return false
        }
        let state = hostFrame(present: false)
        guard state != GHOSTTY_HOST_FRAME_NONE, state != GHOSTTY_HOST_FRAME_HIDDEN else {
            frameOwnership.scale = nil
            return false
        }
        frameOwnership.scale = backing
        return true
    }

    /// After a new display scale or a reveal went to Ghostty while its window's commit owns this terminal's frame:
    /// a pixel size the shown frame does not have waits for the commit that presents its frame with its geometry (a
    /// request that waits already carries it); with nothing to replace, a held scale goes to the layer now.
    func requestPresentIfNeeded() {
        guard frameOwnership.embedderPresents else { return }
        guard isShown, let presenter = framePresenter else { return applyHeldScale() }
        guard !presenter.isWaiting(self) else { return }
        switch hostFrame(present: false) {
        case GHOSTTY_HOST_FRAME_READY, GHOSTTY_HOST_FRAME_PENDING, GHOSTTY_HOST_FRAME_HELD:
            presenter.request(self)
        default:
            applyHeldScale()
        }
    }

    /// After the presenter landed this terminal's frame, outside the Core Animation lock: the copy-mode cursor box
    /// follows the new size, and the grid that size fits goes to the PTY owner (through the coalescer; a size drawn ahead
    /// reported nothing when it went to Ghostty).
    func frameDidLand() {
        copyMode.syncCursor()
        updateSurfaceSize()
    }

    /// Shown again while Ghostty leaves new sizes to cmux: its commit is reported once its frame shows.
    func frameOwnershipDidReveal() {
        guard frameOwnership.embedderPresents else { return }
        framePresenter?.watch(self)
    }

    private var framePresenter: TerminalFramePresenter? { window.map(TerminalFramePresenter.forWindow) }

    /// Made: Ghostty leaves every new host size to this view's window commit, for the surface's whole life. The mode
    /// starts with every frame going through main until a commit is reported (the presenter watches it once it has a
    /// window, ``frameOwnershipDidReveal()``).
    func ownFramesByCommit() {
        guard let surface, !frameOwnership.embedderPresents else { return }
        frameOwnership.embedderPresents = true
        ghostty_surface_set_host_present(surface, GHOSTTY_HOST_PRESENT_EMBEDDER)
        framePresenter?.watch(self)
    }

    /// The layer takes the display scale it held for its frame (``holdsScale(_:)``). The layer has no implicit
    /// animations, and inside the presenter's lock span no transaction may begin or commit: a plain property set.
    private func applyHeldScale() {
        guard let scale = frameOwnership.scale else { return }
        frameOwnership.scale = nil
        layer?.contentsScale = scale
    }

    /// While a size waits, the kept frame rides the wanted frame's anchor edge (the host's area moves on).
    private func keepOrigin() {
        guard let wanted = frameOwnership.wanted else { return }
        let origin = Self.anchoredFrame(size: bounds.size, in: wanted, anchor: frameOwnership.anchor).origin
        if frame.origin != origin { setFrameOrigin(origin) }
    }

    /// A frame of `size` on `anchor`'s edge of `area` (the host is not flipped: its top is `maxY`), leading-aligned.
    static func anchoredFrame(size: CGSize, in area: CGRect, anchor: PaneMotionAnchor) -> CGRect {
        let y = anchor == .bottom ? area.minY : area.maxY - size.height
        return CGRect(x: area.minX, y: y, width: size.width, height: size.height)
    }
}
