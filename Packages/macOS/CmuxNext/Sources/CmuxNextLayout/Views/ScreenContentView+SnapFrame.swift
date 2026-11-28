import AppKit
import CmuxNextDesign

/// A layout change that snaps shows in ONE presented frame: a structural change (a split, a close, a zoom, an unzoom:
/// always, `reconcile`), and a keyboard resize press whose frames snap (Reduce Motion, pane animations off).
///
/// CLOSE MOTION 3 (film cm-b-split-reduce, 120 Hz): a change that took its frames in its own turn showed its terminals
/// torn for one refresh: each pane took its new frame in the change's turn, each terminal asked Ghostty for its new size
/// there, and the pass just before that turn's commit found no frame drawn at it (FRAME OWNER S4 keeps the old bounds and
/// frame until then), so the commit showed the new layout with each terminal at its old size beside its ground.
///
/// The Chromium model: the renderer gets the size before the compositor needs its frame. In a shown, live screen the
/// change's own turn gives each resized pane's content its new size ahead (``PaneHostView/drawAhead(sizeChange:)``, as a
/// key press's first refresh is drawn ahead, T-KEYS 3; each ``PaneCommitSurface`` hears it too), and the screen keeps
/// showing what it showed until a frame tick presents the change in one pass: the panes the change took out stay as they
/// were, the panes it brings back stay hidden, the dividers it took out stay, and the rings and dims keep the state they
/// had (`ScreenFrameInput`). So every frame shows one whole layout: the one before the change, then the one after it.
///
/// The tick that shows it is the first one at which every ``PaneCommitSurface`` of a resized pane reported ready, and
/// at the latest the tick ``commitBound`` refreshes after the change (or the longer bound a surface asked for,
/// ``PaneCommitSurface/commitWaitTicks``, at most ``longestCommitWait``). A surface that is not ready then is late: its
/// pane shows its own ground over its content area (``PaneHostView/showsLateGround``), never the surface's old picture
/// at the pane's new size, until the surface reports.
extension ScreenContentView {
    /// The most frame ticks a change waits for its panes' surfaces before it shows: 3 refreshes, 25 ms at 120 Hz. With
    /// the tick itself, a change shows at most 4 refreshes after its turn.
    static let commitBound = 3
    /// The most frame ticks a change waits for a surface that asks for more than ``commitBound``
    /// (``PaneCommitSurface/commitWaitTicks``): a Chromium page that lays out at a size it took ahead, on an engine
    /// with no resize fence. 8 refreshes, 67 ms at 120 Hz.
    static let longestCommitWait = 8

    /// Whether a change that snapped shows at the next frame tick: a shown screen in a window whose root runs frames,
    /// with a pane whose host changes size. Gives those hosts their sizes ahead now. `keyPress`: the snap is a keyboard
    /// resize press's (Reduce Motion, pane animations off; RESIZE P0 13, KEY SNAP GRID): each size drawn ahead takes its
    /// grid to the program in the key's turn, as a key spring's first refresh does (RESIZE P0 11), so the program redraws
    /// before the tick shows the press. A structural change's (a split, a close, a zoom) is render only: its grid goes
    /// when it shows.
    func holdsSnapForContent(keyPress: Bool = false) -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        let strip = stripShift, scale = self.scale
        var resized = false
        // The panes a change that still waits asked: one this change no longer resizes takes its ask back (below).
        let asked = frameInput.snapWaitsForContent ? frameInput.commitAwaited : []
        frameInput.commitAwaited = []
        for (pane, frame) in paneFrames {
            guard let host = context.hosts[pane], host.superview === self, host.frame.width >= 1, host.frame.height >= 1 else { continue }
            // As `applyPresentation` places it: on the pixel grid where it shows.
            let placed = frame.rect.offsetBy(dx: (geometry.scrolls(pane: pane) ? strip : 0) - areaOffset(of: pane), dy: -rowOffset(of: pane))
                .pixelEdges(scale)
            guard placed.size != host.frame.size else { continue }
            resized = true
            let change = CGSize(width: placed.width - host.frame.width, height: placed.height - host.frame.height)
            host.drawAhead(sizeChange: change, keyPress: keyPress)
            // A newer change of the pane replaces the size an older one gave: the older reports are void. A pane with
            // no surface now (its producer went) owes no report: a ground it shows for one goes when this change shows.
            let surfaces = host.content.paneCommitSurfaces()
            guard !surfaces.isEmpty else {
                frameInput.commitSurfaces[pane] = nil
                continue
            }
            askSurfaces(surfaces, of: pane, change: change)
            frameInput.commitAwaited.insert(pane)
        }
        // A pane the waiting change resized and this one does not (a change taken back in the same wait): its surfaces
        // keep the size they show, and nothing waits for them. One that shows its ground for an older change keeps it
        // until its surfaces report at that size.
        for pane in asked.subtracting(frameInput.commitAwaited) {
            frameInput.commitSurfaces[pane] = nil
            guard let host = context.hosts[pane], host.superview === self else { continue }
            let surfaces = host.content.paneCommitSurfaces()
            if host.showsLateGround, !surfaces.isEmpty {
                askSurfaces(surfaces, of: pane, change: .zero)
            } else {
                for surface in surfaces { surface.commitWillResize(by: .zero) {} }
            }
        }
        guard resized else { return false }
        // The bound is the screen's wait, not one change's: a change that comes while a snap waits keeps the count, so
        // a burst of changes or a held key cannot push the frame out without end. It gets the ticks that are left.
        if !frameInput.snapWaitsForContent { frameInput.snapRefreshesWaited = 0 }
        frameInput.snapAwaitsPrograms = keyPress
        (frameInput.snapWaitsForContent, frameInput.presentationWaiting) = (true, true)
        context.requestFrames()
        return true
    }

    /// Tells `surfaces` of `pane` that the pane's next commit changes their size by `change`, and notes the reports
    /// they owe: the pane's entry stays until each of them reported (``commitSurfaceIsReady(_:_:of:)``).
    private func askSurfaces(_ surfaces: [any PaneCommitSurface], of pane: PaneID, change: CGSize) {
        frameInput.commitGeneration &+= 1
        let generation = frameInput.commitGeneration
        frameInput.commitSurfaces[pane] = (generation, Array(repeating: false, count: surfaces.count), Self.commitBound)
        for (index, surface) in surfaces.enumerated() {
            surface.commitWillResize(by: change) { [weak self] in self?.commitSurfaceIsReady(pane, index, of: generation) }
        }
        // A surface that reported in its call owes nothing: only one still owed may ask the change to wait longer.
        guard let entry = frameInput.commitSurfaces[pane], entry.generation == generation else { return }
        let asked = surfaces.indices.compactMap { entry.ready[$0] ? nil : surfaces[$0].commitWaitTicks }.max() ?? 0
        frameInput.commitSurfaces[pane]?.bound = min(Self.longestCommitWait, max(Self.commitBound, asked))
    }

    /// A surface of `pane` reported that its picture at the change's size shows now. A report of an older change is void.
    /// A pane that showed its ground for it (the change showed at its bound) shows its content again once all of its
    /// surfaces reported.
    private func commitSurfaceIsReady(_ pane: PaneID, _ index: Int, of generation: UInt64) {
        guard var entry = frameInput.commitSurfaces[pane], entry.generation == generation, entry.ready.indices.contains(index) else { return }
        entry.ready[index] = true
        guard entry.ready.allSatisfy({ $0 }) else { return frameInput.commitSurfaces[pane] = entry }
        frameInput.commitSurfaces[pane] = nil
        // A change that still waits shows the pane, with its picture at the new size, when it shows (`presentHeldSnap`).
        if frameInput.snapWaitsForContent, frameInput.commitAwaited.contains(pane) { return }
        context.hosts[pane]?.showsLateGround = false
    }

    /// Whether a held snap waits on at this frame tick. Counts this tick.
    ///
    /// Any held snap waits for the ``PaneCommitSurface``s of its resized panes, at most ``commitBound`` ticks (each
    /// pane's own bound: longer when one of its surfaces asked, ``PaneCommitSurface/commitWaitTicks``).
    ///
    /// A key press's snap also waits for its terminals' programs (RESIZE P0 20; films px-keys-held-2-s1r-claude under
    /// Reduce Motion, cmux21 1x 120 Hz): the press's grid went to each resized terminal's program with its size drawn
    /// ahead, and a full-screen program that has not redrawn at it by the tick would show its old picture in the new pane
    /// (the terminal's presenter keeps its old size and picture for the redraw, while the pane, its divider and its ground
    /// take the new size: the program's rules and status line end at the old width for a refresh). So the snap waits with
    /// the terminal, as a key spring's frames do (``PaneMotionHoldFollowing/aheadOfFollowAwaitsContent(refreshesWaited:)``,
    /// each content bounds its wait), and the tick that shows it shows the redraw with the new size in one commit. A
    /// structural snap (a split, a close, a zoom) does not wait for programs: its grid goes when it shows.
    func heldSnapAwaitsContent() -> Bool {
        guard frameInput.snapWaitsForContent, window != nil, !isHiddenOrHasHiddenAncestor else { return false }
        frameInput.snapRefreshesWaited += 1
        let waited = frameInput.snapRefreshesWaited
        if frameInput.commitAwaited.contains(where: { frameInput.commitSurfaces[$0].map { waited <= $0.bound } ?? false }) { return true }
        guard frameInput.snapAwaitsPrograms else { return false }
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
            // A surface that did not report by the bound is late: its pane shows its own ground until it does. Each
            // pane this commit places shows its ground only for a report it is still owed: one whose producer went (an
            // older change left it late, and this one found no surface in it) shows its content again here.
            let late = frameInput.commitSurfaces[pane] != nil
            if late, !host.showsLateGround { lateSurfaceCommits += 1 }
            host.showsLateGround = late
        }
        frameInput.commitAwaited = []
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

    /// The pass that shows a layout change begins, before it places the panes: what the change took out goes
    /// (``hideSnapDeparted()``), the docks' backdrops and the stacking order become the new layout's (`reconcileDock`,
    /// then a canvas's own order), and the rings and dims asked for since the change show (`updateChrome`). They are
    /// part of what a frame shows, so they change with the panes: a dock a zoom takes out keeps its backdrop under its
    /// panes until the frame that shows the zoom, one an unzoom brings back gets its backdrop in the frame that shows
    /// its panes, and the pane that gets the focus at a close keeps its dim while the closed pane shows. The pass is
    /// the change's own turn when nothing waits (it resizes no pane, and the turn does not hold its presentations),
    /// else the presentation the change waited for. A pass with no layout change before it does nothing here.
    func beginShowingChange() {
        hideSnapDeparted()
        guard frameInput.changeIsUnshown else { return }
        frameInput.changeIsUnshown = false
        // A timed change's panes show in this pass's commit: its first frame (a right split's picture was its first
        // frame, `openSplitFromSnapshot`).
        showTimedChange(pictured: snapshotOpen != nil)
        if frameInput.showsSplit {
            frameInput.showsSplit = false
            // The split's live panes show in this pass's commit: a picture over them goes after its slide.
            if snapshotOpen != nil { snapshotOpenLiveShown() }
        }
        reconcileDock()
        reconcileCanvasStacking()
        guard let chrome = frameInput.heldChrome else { return }
        frameInput.heldChrome = nil
        chrome()
    }

    /// The panes and dividers a change took out go. A pane a later change took back stays (it is in the layout again).
    /// The hosts hide here, and a close's hosts are torn down after this turn's commit, so the frame that shows the
    /// change carries no teardown (RESIZE VIDEOS F1: a teardown in a close's first frames missed refreshes).
    func hideSnapDeparted() {
        if !frameInput.snapDepartedDividers.isEmpty {
            for view in frameInput.snapDepartedDividers { view.removeFromSuperview() }
            frameInput.snapDepartedDividers = []
        }
        guard !frameInput.snapDeparted.isEmpty else { return }
        frameInput.snapDeparted = []
        guard zoomDim.hidesDeparted(of: self) else { return }
        context.afterCommit { [weak self] in self?.releaseDeparted() }
    }

    /// Tears down the hosts of the panes a close took out of this screen, once the close showed (`until` nil: every
    /// host the screen kept, a zoom's too: the screen goes).
    func releaseDeparted(until: LayoutViewContext.Retirement? = .landing) {
        context.releaseRetired(of: screenID, until: until)
    }

    /// In the presentation that shows a change, once it placed the panes: the panes the change brought back hidden (a
    /// zoom's covered panes at the unzoom) show, at their places. Returns whether any did.
    func showSnapReturning() -> Bool {
        guard !frameInput.snapReturning.isEmpty else { return false }
        defer { frameInput.snapReturning = [] }
        return context.showReturning(frameInput.snapReturning.filter { paneFrames[$0] != nil }, on: self)
    }
}
