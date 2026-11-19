import AppKit
import CmuxNextDesign

/// A screen's floating panes as its view holds them: the model's list, the cards under the panes, their look and a
/// pointer's move or resize of one.
struct FloatingPanesState {
    enum Change { case none, frames, panes }

    /// The model's list, back to front (``LayoutScreen/floating``); set by the root before each update.
    var list: [LayoutFloatingPane] = []
    /// The list the last `update(layout:)` took.
    private var taken: [LayoutFloatingPane] = []
    /// A pointer's move or resize in progress.
    var drag: FloatingPaneDrag?
    /// The card under each floating pane.
    var cards: [PaneID: FloatingPaneCardView] = [:]
    /// The cards' look now (the Floating Pane knobs), and the tracked read that tells a knob's change.
    var look = FloatingPaneLook()
    let lookWatch = FloatingPaneLookWatch()

    /// What changed in the list since the last update: its set of panes, only a frame or the order, or nothing.
    mutating func takeChange() -> Change {
        defer { taken = list }
        if Set(taken.map(\.pane)) != Set(list.map(\.pane)) { return .panes }
        return taken == list ? .none : .frames
    }

    /// The list to place: the model's, with the frame a pointer's drag shows.
    var shown: [LayoutFloatingPane] {
        guard let drag else { return list }
        return list.map { $0.pane == drag.pane ? LayoutFloatingPane(pane: $0.pane, frame: drag.frame) : $0 }
    }

    /// Puts each card around its pane's host, where that shows now in `view`, with the look and with corners by
    /// the look's corner mode; gives the host the content's radius and, for a see-through look, gives the
    /// pane's ground to the card. Each card gets the resize band of the look around it, inside the pane area, and
    /// the frames of the cards in front of it. The window's radius is read once for the pass. Returns true when a
    /// card moved.
    func present(in view: NSView, hosts: [PaneID: PaneHostView], padding: CGFloat, wholeCard: Bool) -> Bool {
        guard !cards.isEmpty else { return false }
        let window = view.window, windowRadius = window?.frameCornerRadius ?? 0, windowSize = window?.frame.size ?? .zero
        // A window with square corners (full screen) has the titled window's radius for the two fixed modes.
        let titled = windowRadius > 0 ? windowRadius : Metrics.standardWindowCornerRadius
        var changed = false
        let reach = FloatingPaneReach(band: look.resizeBand, corner: look.cornerZone), area = CGRect(origin: .zero, size: view.bounds.size)
        // Front to back: a card knows the cards in front of it. A card whose pane is not in the list goes last.
        let listed = shown.reversed().map(\.pane).filter { cards[$0] != nil }
        var front: [CGRect] = []
        for pane in listed + cards.keys.filter({ !listed.contains($0) }) {
            guard let card = cards[pane], let host = hosts[pane], host.superview === view else { continue }
            let frame = LayoutFloatingPane.cardRect(aroundPane: host.frame)
            if card.place(frame, reach: reach, in: area, under: front) { changed = true }
            if card.isHidden != host.isHidden { card.isHidden = host.isHidden }
            if !card.isHidden { front.append(card.frame) }
            let inWindow = view.convert(frame, to: nil)
            let corners: FloatingPaneCorners = switch look.cornerMode {
            case .concentric:
                FloatingPaneCorners(size: frame.size, left: inWindow.minX, top: windowSize.height - inWindow.maxY,
                                    right: windowSize.width - inWindow.maxX, bottom: inWindow.minY,
                                    windowRadius: windowRadius, floor: look.cornerFloor)
            case .window: FloatingPaneCorners(uniform: titled)
            case .mainPane: FloatingPaneCorners(uniform: Metrics.mainPaneCornerRadius(windowCornerRadius: windowRadius))
            }
            card.show(look: look, corners: corners)
            // One radius for the content's 4 corners (the host's clip takes one): the largest corner's.
            host.applyShape(padding: padding, cornerRadius: corners.contentRadius(inset: LayoutFloatingPane.rimWidth + padding), wholeCard: wholeCard)
            card.paintGround(of: host, seeThrough: look.isSeeThrough)
        }
        return changed
    }

    /// The covers that cut a pane's content (`covers`: the frames of the panes in front of it), less each floating
    /// card while the look is see-through: the panes under such a card show through it. A card's cover is the card's
    /// frame of this pass (the card, not its band), so it is found by that frame.
    func contentCovers(_ covers: [CGRect]) -> [CGRect] {
        guard look.isSeeThrough, !covers.isEmpty, !cards.isEmpty else { return covers }
        return covers.filter { cover in !cards.values.contains { $0.cardFrame == cover } }
    }
}
