import AppKit
import CmuxNextDesign
import GhosttyNextKit

/// A terminal's frame state while its window's commit presents its new sizes (``TerminalSurfaceView/place(_:)``).
struct TerminalFrameOwnership {
    /// Ghostty leaves new host sizes to cmux (`ghostty_surface_set_host_present` EMBEDDER).
    var embedderPresents = false
    /// The display scale the layer takes with the frame drawn at it (its window moved to a display of another scale,
    /// ``TerminalSurfaceView/holdsScale(_:)``); until the presenter's next pass the layer keeps the scale of the frame
    /// it shows.
    var scale: CGFloat?
}

/// FRAME OWNER REFACTOR S4 (`motion.frameOwner.terminals`), cmux-ad m18: in every commit a terminal's bounds are the
/// frame its host gives it, and the frame Ghostty drew at that size shows with them when it is drawn by that commit; a
/// frame not drawn yet shows in the next commit after it is (``TerminalFramePresenter``). Nothing keeps an old size.
extension TerminalSurfaceView {
    /// Places the surface at `frame` in its host, at once, whatever the switch: the view's bounds are its pane's area in
    /// this commit, and `ghostty_surface_set_size` gets the new pixel size in this turn (`setFrameSize`), so Ghostty draws
    /// that size now (the reflow preview re-wraps the text at it). Switch on: the window's presenter shows the frame drawn
    /// at the new size with these bounds before this turn's commit if it is drawn by then, else as soon as it is (a late
    /// landing, counted). Switch off: Ghostty's renderer shows it (its display pass).
    func place(_ frame: CGRect) { // perf-hot: 1ms motion-frame (each frame of a key resize)
        let owned = TerminalDragTunables.framesOwnedByCommit.value
        if owned != frameOwnership.embedderPresents { setFramesOwnedByCommit(owned) }
        let resized = frame.size != self.frame.size
        if self.frame != frame { self.frame = frame }
        guard resized, owned, isShown, window != nil, surface != nil else { return }
        requestNewSizeFrame()
    }

    /// After a new size or scale went to Ghostty while its window's commit presents this terminal's frames: the frame
    /// drawn at it presents with the view's geometry in the next pass, or, with nothing shown or the surface hidden, the
    /// held scale goes to the layer now and a first frame presents itself.
    private func requestNewSizeFrame() {
        guard let presenter = framePresenter else { return applyHeldScale() }
        switch hostFrame(present: false) {
        case GHOSTTY_HOST_FRAME_NONE:
            applyHeldScale()
            presenter.watch(self)
        case GHOSTTY_HOST_FRAME_HIDDEN, GHOSTTY_HOST_FRAME_SHOWN:
            applyHeldScale()
        default:
            presenter.request(self)
        }
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

    /// The switch, a window change: the presenter lets go of this terminal, and a held scale goes to the layer.
    func releaseFrameOwnership() {
        guard frameOwnership.embedderPresents else { return }
        framePresenter?.cancel(self)
        applyHeldScale()
    }

    /// A new display scale `backing` while its window's commit owns this terminal's frame, and its layer shows a
    /// frame: the layer keeps the scale of that frame until the presenter's next pass, which shows the frame drawn at it
    /// with `backing` when it is drawn, or gives the layer `backing` then anyway (a late landing, m18: no keep across
    /// commits). Returns whether it
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
    /// a pixel size the shown frame does not have goes to the presenter's next pass (a request that waits already
    /// carries it); with nothing to replace, a held scale goes to the layer now.
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
    /// follows the new size (it reads Ghostty under the terminal's lock, so never inside the lock span).
    func frameDidLand() {
        copyMode.syncCursor()
    }

    /// Shown again while Ghostty leaves new sizes to cmux: its commit is reported once its frame shows.
    func frameOwnershipDidReveal() {
        guard frameOwnership.embedderPresents else { return }
        framePresenter?.watch(self)
    }

    private var framePresenter: TerminalFramePresenter? { window.map(TerminalFramePresenter.forWindow) }

    private func setFramesOwnedByCommit(_ owned: Bool) {
        guard let surface else { return }
        if !owned { releaseFrameOwnership() }
        frameOwnership.embedderPresents = owned
        ghostty_surface_set_host_present(surface, owned ? GHOSTTY_HOST_PRESENT_EMBEDDER : GHOSTTY_HOST_PRESENT_RENDERER)
        // The mode starts with every frame going through main until a commit is reported.
        if owned { framePresenter?.watch(self) }
    }

    /// The layer takes the display scale it held for its frame (``holdsScale(_:)``). The layer has no implicit
    /// animations, and inside the presenter's lock span no transaction may begin or commit: a plain property set.
    func applyHeldScale() {
        guard let scale = frameOwnership.scale else { return }
        frameOwnership.scale = nil
        layer?.contentsScale = scale
    }
}
