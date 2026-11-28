import AppKit
import CmuxNextDesign

/// The screen's side of the frame-timing log (goal instant-splits, `TransitionFrameLog`): which transition a layout
/// change is, the pass that shows it (its first frame), what that frame showed (`surface`, `blank_first_frame`) and how
/// far the panes rest from their targets at the settle (`drift_px`). Measurement only: nothing here changes what shows.
/// With no log (`LayoutViewContext.frameTiming` nil: package tests, tools) every entry costs one optional check.
extension ScreenContentView {
    /// The side transitions: the sidebar's slide resizes the screen (``setFrameSize(_:)``).
    static let sideTransitions: Set<TransitionFrameLog.Transition> = [.sideOpen, .sideClose]

    /// The update's change, timed from the input this turn handles: a right split (`right_split_open`), another split,
    /// a close, a zoom or an unzoom. A change that keeps the pane count (a pane moved or swapped) is not timed here (the
    /// split-move bench films those). Only a shown screen in a window times.
    func timeChange(to layout: ScreenLayout, tiledChange: Bool, rightSplit: Bool, zooming: Bool, unzooming: Bool) {
        guard tiledChange || zooming || unzooming else { return }
        frameInput.timedChange = nil
        guard let timing = context.frameTiming, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let before = self.layout.panes.count, after = layout.panes.count
        let kind: TransitionFrameLog.Transition? =
            rightSplit ? .rightSplitOpen
            : zooming ? .zoom
            : unzooming ? .unzoom
            : after > before ? .splitOpen
            : after < before ? .paneClose
            : nil
        guard let kind else { return }
        timing.arm(kind)
        timing.input()
        frameInput.timedChange = kind
        frameInput.timedPanesBefore = Set(paneFrames.keys)
    }

    /// The pass that shows the timed change begins (``beginShowingChange()``): its commit is the first frame. A right
    /// split with a picture over it (`pictured`) was marked at the picture (``openSplitFromSnapshot(giver:end:)``).
    func showTimedChange(pictured: Bool) {
        guard let kind = frameInput.timedChange else { return }
        frameInput.timedChange = nil
        let before = frameInput.timedPanesBefore
        frameInput.timedPanesBefore = []
        guard let timing = context.frameTiming, !(kind == .rightSplitOpen && pictured) else { return }
        let look = firstFrameLook(resizedFrom: before)
        timing.changed(in: window, path: kind == .rightSplitOpen ? "live" : nil, surface: look.surface, blank: look.blank,
                       drift: { [weak self] in self?.restDrift() }, for: [kind])
    }

    /// The snapshot right split's first frame is its picture: the giver's content resized, the new pane a flat fill
    /// (blank by design).
    func markSnapshotSplit(giver: PaneHostView) {
        guard let timing = context.frameTiming else { return }
        timing.changed(in: window, path: "snapshot", endsAtDisplay: true,
                       surface: context.provider?.transitionSurface(for: giver.pane)?.kind, blank: true,
                       drift: { [weak self] in self?.restDrift() }, for: [.rightSplitOpen])
    }

    /// The screen resized (``setFrameSize(_:)``): a sidebar toggle's first frame, or a move of a transition settling.
    func noteTimedResize() {
        guard let timing = context.frameTiming else { return }
        if let pending = timing.pendingTransition, Self.sideTransitions.contains(pending) {
            let look = firstFrameLook(resizedFrom: Set(paneFrames.keys))
            timing.changed(in: window, surface: look.surface, blank: look.blank, drift: { [weak self] in self?.restDrift() },
                           for: Self.sideTransitions)
        } else if timing.isSettling {
            timing.moved(in: window)
        }
    }

    /// A divider drag's change (each frame's, and the release's): its first is the first frame, with the kind of the
    /// panes it shows (a drag has no blank signal: no held snap, so no late ground); later ones are its moves.
    func noteDragChange() {
        guard let timing = context.frameTiming else { return }
        guard timing.pendingTransition == .dividerDrag else { return timing.changed(in: window, for: [.dividerDrag]) }
        timing.changed(in: window, surface: firstFrameLook(resizedFrom: Set(paneFrames.keys)).surface,
                       drift: { [weak self] in self?.restDrift() }, for: [.dividerDrag])
    }

    /// A motion frame moved the panes: a move of the transition settling, if one is. One comparison otherwise.
    func noteTimedMotion() {
        guard let timing = context.frameTiming, timing.isSettling else { return }
        timing.moved(in: window)
    }

    /// What the first frame shows: the content kind of the panes it shows (`mixed` for more than one, nil with no
    /// provider) and whether any shows no content. A pane from before the change is blank when it shows its late
    /// ground (its surface missed the held snap's bound); a new or returning one when its content has not presented.
    /// O(shown panes), once per timed transition.
    func firstFrameLook(resizedFrom before: Set<PaneID>) -> (surface: String?, blank: Bool?) {
        let provider = context.provider
        var kinds: Set<String> = [], blank = false, known = false
        for pane in paneFrames.keys {
            guard let host = context.hosts[pane], host.superview === self, !host.isHidden || frameInput.snapReturning.contains(pane) else { continue }
            let surface = provider?.transitionSurface(for: pane)
            if let surface { kinds.insert(surface.kind) }
            if host.showsLateGround {
                (blank, known) = (true, true)
            } else if !before.contains(pane) || frameInput.snapReturning.contains(pane) {
                if let surface { (blank, known) = (blank || !surface.presented, true) }
            } else {
                known = true
            }
        }
        let surface = kinds.count > 1 ? "mixed" : kinds.first
        return (surface, known ? blank : nil)
    }

    /// The largest distance, in device pixels, between a shown pane's frame edge and its pixel-aligned rest rect (as
    /// `applyPresentation` places it at rest). 0: every pane landed exactly. nil: no pane shows.
    func restDrift() -> Double? {
        guard window != nil else { return nil }
        let scale = self.scale, restStrip = geometry.viewShift(offset: isUserScrolling ? scroll.value : scroll.target)
        var drift: CGFloat?
        for (pane, frame) in paneFrames {
            guard let host = context.hosts[pane], host.superview === self, !host.isHidden else { continue }
            let rest = frame.targetRect.offsetBy(dx: (geometry.scrolls(pane: pane) ? restStrip : 0) - areaOffset(of: pane),
                                                 dy: -rowOffset(of: pane)).pixelEdges(scale)
            let shown = host.frame
            let edge = max(abs(shown.minX - rest.minX), abs(shown.minY - rest.minY), abs(shown.maxX - rest.maxX), abs(shown.maxY - rest.maxY))
            drift = max(drift ?? 0, edge * scale)
        }
        return drift.map(Double.init)
    }
}
