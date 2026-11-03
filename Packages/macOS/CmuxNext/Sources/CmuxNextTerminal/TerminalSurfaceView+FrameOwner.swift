import AppKit
import CmuxNextDesign
import GhosttyNextKit

/// A terminal's size request while its window's commit owns its frame (``TerminalSurfaceView/place(_:anchor:)``).
struct TerminalFrameOwnership {
    /// Ghostty leaves new host sizes to cmux (`ghostty_surface_set_host_present` EMBEDDER).
    var embedderPresents = false
    /// The frame the host wants now.
    var wanted: CGRect?
    /// The edge a kept frame rides while the host's area moves.
    var anchor: PaneMotionAnchor = .top
    /// The size asked of Ghostty and not shown yet (one at a time).
    var inFlight: CGSize?
    /// The view takes the size Ghostty already has: no new size goes to Ghostty.
    var landing = false
}

/// FRAME OWNER REFACTOR S4 (`motion.frameOwner.terminals`): in every commit a terminal's bounds and its pixels change
/// together, or both keep their last size (``TerminalFramePresenter``).
extension TerminalSurfaceView {
    /// Places the surface at `frame` in its host. Switch off: at once; Ghostty's frame of a new size lands 1-4
    /// refreshes later. On: a new size goes to Ghostty and the view keeps its size, its old frame on the `anchor` edge
    /// of `frame` (the host clips it and paints the terminal background beside it), until its window's commit shows
    /// the frame drawn at the new size with the new bounds. One size waits at a time; the newest goes next.
    func place(_ frame: CGRect, anchor: PaneMotionAnchor) {
        let owned = TerminalDragTunables.framesOwnedByCommit.value
        if owned != frameOwnership.embedderPresents { setFramesOwnedByCommit(owned) }
        guard owned, isShown, window != nil, surface != nil else {
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
    func requestWantedFrame() {
        guard frameOwnership.embedderPresents, isShown, let wanted = frameOwnership.wanted,
              let presenter = framePresenter else { return }
        guard wanted.size != bounds.size else {
            if frame != wanted { frame = wanted }
            return
        }
        frameOwnership.inFlight = wanted.size
        // `ghostty_surface_set_size` at the asked size, and the grid report as for any new size.
        updateSurfaceSize()
        keepOrigin()
        presenter.request(self)
    }

    /// Inside the commit: the view takes the size Ghostty's shown frame has, on the anchor edge of the wanted frame,
    /// and its layer the same geometry in this commit. Returns whether it wants another size since.
    func landRequestedFrame() -> Bool {
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

    /// The switch, a window change: a size that waits takes its bounds now, through the usual path.
    func releaseFrameOwnership() {
        guard frameOwnership.embedderPresents else { return }
        framePresenter?.cancel(self)
        guard frameOwnership.inFlight != nil, let wanted = frameOwnership.wanted else { return }
        frameOwnership.inFlight = nil
        if frame != wanted { frame = wanted }
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
