import AppKit

/// CLOSE MOTION 3 (film cm-b-split-reduce, 120 Hz): a structural change whose frames snap (Reduce Motion, pane
/// animations off) showed its terminals torn for one refresh: each pane took its new frame in the change's turn, each
/// terminal asked Ghostty for its new size there, and the pass just before that turn's commit found no frame drawn at it
/// (FRAME OWNER S4 keeps the old bounds and frame until then), so the commit showed the new layout with each terminal at
/// its old size beside its ground.
///
/// The Chromium model: the renderer gets the size before the compositor needs its frame. In a shown, live screen the
/// snapped change's own turn gives each resized pane's content its new size ahead, render only
/// (``PaneHostView/drawAhead(sizeChange:)``, as a key press's first refresh is drawn ahead, T-KEYS 3), and the screen
/// keeps showing what it showed, the panes the change took out included, until the next frame tick presents the change
/// in one pass (as a key press's turn presents nothing until its first tick, S1B). That tick's layout finds each
/// terminal's frame drawn at its new size, and the presenter shows it with its bounds in that commit.
extension ScreenContentView {
    /// Whether a change that snapped shows at the next frame tick: a shown screen in a window whose root runs frames,
    /// with a pane whose host changes size. Gives those hosts their sizes ahead now. `keyPress`: the snap is a keyboard
    /// resize press's (Reduce Motion, pane animations off; RESIZE P0 13, KEY SNAP GRID): each size drawn ahead takes its
    /// grid to the program in the key's turn, as a key spring's first refresh does (RESIZE P0 11), so the program redraws
    /// before the tick shows the press. A structural change's (a split, a close, a zoom) is render only: its grid goes
    /// when it shows (m58).
    func holdsSnapForContent(keyPress: Bool = false) -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        let strip = stripShift, scale = self.scale
        var resized = false
        for (pane, frame) in paneFrames {
            guard let host = context.hosts[pane], host.superview === self, host.frame.width >= 1, host.frame.height >= 1 else { continue }
            // As `applyPresentation` places it: on the pixel grid where it shows.
            let placed = frame.rect.offsetBy(dx: (geometry.scrolls(pane: pane) ? strip : 0) - areaOffset(of: pane), dy: -rowOffset(of: pane))
                .pixelEdges(scale)
            guard placed.size != host.frame.size else { continue }
            resized = true
            host.drawAhead(sizeChange: CGSize(width: placed.width - host.frame.width, height: placed.height - host.frame.height), keyPress: keyPress)
        }
        guard resized else { return false }
        // A press while a press's snap waits keeps its count: the wait stays bounded under a held key.
        if !frameInput.snapWaitsForContent { frameInput.snapRefreshesWaited = 0 }
        frameInput.snapAwaitsPrograms = keyPress
        (frameInput.snapWaitsForContent, frameInput.presentationWaiting) = (true, true)
        context.requestFrames()
        return true
    }

    /// Whether a key press's held snap waits on at this frame tick (RESIZE P0 20; films px-keys-held-2-s1r-claude under
    /// Reduce Motion, cmux21 1x 120 Hz): the press's grid went to each resized terminal's program with its size drawn
    /// ahead, and a full-screen program that has not redrawn at it by the tick would show its old picture in the new pane
    /// (the terminal's presenter keeps its old size and picture for the redraw, while the pane, its divider and its ground
    /// take the new size: the program's rules and status line end at the old width for a refresh). So the snap waits with
    /// the terminal, as a key spring's frames do (``PaneMotionHoldFollowing/aheadOfFollowAwaitsContent(refreshesWaited:)``,
    /// each content bounds its wait), and the tick that shows it shows the redraw with the new size in one commit. A
    /// structural snap (a split, a close, a zoom) never waits here: its grid goes when it shows (m58). Counts this tick.
    func heldSnapAwaitsContent() -> Bool {
        guard frameInput.snapWaitsForContent, frameInput.snapAwaitsPrograms, window != nil, !isHiddenOrHasHiddenAncestor
        else { return false }
        frameInput.snapRefreshesWaited += 1
        let waited = frameInput.snapRefreshesWaited
        for pane in paneFrames.keys {
            guard let host = context.hosts[pane], host.superview === self else { continue }
            if host.snapAwaitsContent(refreshesWaited: waited) { return true }
        }
        return false
    }

    /// The frame tick (or a settle: the screen parks, Reduce Motion lands everything) shows the held snap.
    func presentHeldSnap() {
        guard frameInput.snapWaitsForContent else { return }
        (frameInput.snapWaitsForContent, frameInput.snapAwaitsPrograms) = (false, false)
        // The snap waited for its content (bounded): each terminal it places shows at its new size in this commit, with
        // its program's redraw or the size only, never its old size in the new pane (RESIZE P0 21).
        for pane in paneFrames.keys {
            guard let host = context.hosts[pane], host.superview === self else { continue }
            host.snapWillShow()
        }
        applyPresentation()
        releaseUntakenAhead()
    }

    /// Each pane host of this screen lets a size drawn ahead go that no placement took (``PaneHostView/snapDidShow()``):
    /// the held snap showed, or a key press was taken back in its own turn. `restingOnly`: only the panes no spring moves
    /// (the key's turn while other panes or the camera still move: no hold begins or ends for a pane at rest, so nothing
    /// else lets its size go; a pane on a spring keeps its size for its hold). A host with no such size does nothing.
    /// O(panes of the screen).
    func releaseUntakenAhead(restingOnly: Bool = false) {
        for (pane, frame) in paneFrames where !restingOnly || frame.rect == frame.targetRect {
            guard let host = context.hosts[pane], host.superview === self else { continue }
            host.snapDidShow()
        }
    }

    /// In the presentation that shows the held snap: the panes it took out go, unless a later change took them back.
    func releaseSnapDeparted() {
        guard !frameInput.snapDeparted.isEmpty else { return }
        for pane in frameInput.snapDeparted where paneFrames[pane] == nil && !context.livePanes.contains(pane) {
            context.release(pane)
        }
        frameInput.snapDeparted = []
    }
}
