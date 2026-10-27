import AppKit
import CmuxNextDesign

/// A split's new pane fading in at its rest (``SplitArrival/fade``; plans/cmux-next/motion-first-principles.md).
///
/// The change's turn lays the split out once at its final layout (`ScreenContentView.reconcile`). At the end of
/// that turn, after the panes and their chrome are placed, the new pane's host layer and its chrome's layer are
/// held at opacity 0 on the render server until its content drew its first frame
/// (`LayoutPaneContentProvider.whenPaneContentDrawn`, at most ``SplitArrival/firstFrameWait``), then fade in
/// (`MotionFade.fadeIn`, ease-out). The model opacity stays 1: the pane takes the keyboard, clicks and its layout
/// in the key's turn, and the main thread does no work per fade frame.
struct SplitFades {
    /// The panes this turn's split added, waiting for the turn's end (``ScreenContentView/beginSplitFades()``).
    var pending: Set<PaneID> = []
    /// Each fading pane's wait and what cancels its content's first-frame wait.
    private var running: [PaneID: (wait: FadeInWait, cancelContent: (@MainActor () -> Void)?)] = [:]

    /// The panes a change fades in: with ``SplitArrival/fade``, the pane a split added beside the pane that gave
    /// up its room, or a handoff's giver (the pane that shows the new content). A new dock column grows in.
    static func fading(_ arrivals: [PaneID: PaneArrival], handoff giver: PaneID?, arrival: SplitArrival) -> Set<PaneID> {
        guard arrival == .fade else { return [] }
        if let giver { return [giver] }
        return Set(arrivals.filter { $0.value.source == .split }.keys)
    }

    /// `pane` fades in on `wait` (``cancel(_:)`` ended any earlier fade of it first, before the new hold was added:
    /// both holds use one key on the same layers).
    mutating func track(_ pane: PaneID, wait: FadeInWait, cancelContent: (@MainActor () -> Void)?) {
        running[pane] = (wait, cancelContent)
    }

    /// The hold of `pane` is over (its fade landed, or the content's fade replaced it): the content's first-frame
    /// wait, if still open, stops.
    mutating func ended(_ pane: PaneID, wait: FadeInWait) {
        guard let entry = running[pane], entry.wait === wait else { return }
        running[pane] = nil
        entry.cancelContent?()
    }

    /// `pane` left the screen: it shows at rest, and nothing waits for it.
    mutating func cancel(_ pane: PaneID) {
        pending.remove(pane)
        guard let entry = running.removeValue(forKey: pane) else { return }
        entry.cancelContent?()
        entry.wait.cancel()
    }

    mutating func cancelAll() {
        pending = []
        for pane in Array(running.keys) { cancel(pane) }
    }
}

extension ScreenContentView {
    /// Starts the fades of the panes this turn's split added: the overlay plane places their chrome now, so the
    /// chrome fades with its pane, then each pane's host and chrome layers are held at 0 until its content drew.
    /// No fade (the gate does not fade, a window on no live display, a host gone) shows the pane in this frame.
    func beginSplitFades() {
        guard !splitFades.pending.isEmpty else { return }
        let panes = splitFades.pending
        splitFades.pending = []
        context.overlaySyncNow()
        for pane in panes {
            guard let host = context.hosts[pane], holds(host), let layer = host.layer else { continue }
            // A pane fading in already (a handoff giver split again) restarts: its old hold goes before the new one.
            splitFades.cancel(pane)
            let layers = [layer] + [host.chrome.layer].compactMap { $0 }
            guard let wait = Motion.panes.fadeIn(.fadeIn, layers: layers, in: host, waitingUpTo: SplitArrival.firstFrameWait,
                                                 ended: { [weak self] wait in self?.splitFades.ended(pane, wait: wait) }) else { continue }
            let cancelContent = context.provider?.whenPaneContentDrawn(pane) { [weak wait] in wait?.contentDrawn() }
            splitFades.track(pane, wait: wait, cancelContent: cancelContent)
        }
    }
}
