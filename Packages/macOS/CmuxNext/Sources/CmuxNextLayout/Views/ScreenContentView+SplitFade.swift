import AppKit
import CmuxNextDesign

/// A split's new pane fading in at its rest (``SplitArrival/fade``; plans/cmux-next/motion-first-principles.md).
///
/// The change's turn lays the split out once at its final layout (`ScreenContentView.reconcile`). At the end of
/// that turn, after the panes and their chrome are placed, the new pane's host layer and its chrome's layer fade in
/// on the render server (`MotionFade.fadeIn`, ease-out), from that turn. The pane comes in on its own background
/// (a terminal host paints its theme background in the key's turn; over a see-through window the window's sheet
/// shows through it), so nothing waits for the content: the content provider fades the content in when it first
/// draws (`LayoutPaneContentProvider.paneArrived`). The model opacity stays 1: the pane takes the keyboard, clicks
/// and its layout in the key's turn, and the main thread does no work per fade frame.
struct SplitFades {
    /// The panes this turn's split added, waiting for the turn's end (``ScreenContentView/beginSplitFades()``).
    var pending: Set<PaneID> = []

    /// The panes a change fades in: with ``SplitArrival/fade``, the pane a split added beside the pane that gave
    /// up its room, or a handoff's giver (the pane that shows the new content). A new dock column grows in.
    static func fading(_ arrivals: [PaneID: PaneArrival], handoff giver: PaneID?, arrival: SplitArrival) -> Set<PaneID> {
        guard arrival == .fade else { return [] }
        if let giver { return [giver] }
        return Set(arrivals.filter { $0.value.source == .split }.keys)
    }

    /// `pane` left the screen before its turn ended: nothing fades it.
    mutating func cancel(_ pane: PaneID) { pending.remove(pane) }

    mutating func cancelAll() { pending = [] }
}

extension ScreenContentView {
    /// Starts the fades of the panes this turn's split added: the overlay plane places their chrome now, so the
    /// chrome fades with its pane, then each pane's host and chrome layers fade in from this turn and the provider
    /// hears that the pane arrived (its content fades in when it draws). With no fade (the gate does not fade, a
    /// window on no live display) the pane shows in this frame and its content as it draws.
    func beginSplitFades() {
        guard !splitFades.pending.isEmpty else { return }
        let panes = splitFades.pending
        splitFades.pending = []
        context.overlaySyncNow()
        for pane in panes {
            guard let host = context.hosts[pane], holds(host), let layer = host.layer else { continue }
            Motion.panes.fadeIn(.fadeIn, layers: [layer] + [host.chrome.layer].compactMap { $0 }, in: host)
            context.provider?.paneArrived(pane)
        }
    }
}
