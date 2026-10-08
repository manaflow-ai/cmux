import AppKit
import CmuxNextDesign
import Observation

/// The card stack above the sidebar's bottom band (R114): the front card
/// with up to two narrower cards peeking below it; on hover every card
/// shows in a column. Announcement cards appear only while the sidebar is
/// revealed (R100). Follows ``SidebarModel/cards`` through observation.
final class SidebarCardStackView: NSView {
    var onAction: ((String, SidebarCardAction) -> Void)?
    /// The stack's height changed; the sidebar lays out again.
    var onHeightChange: (() -> Void)?
    var revealed = false {
        didSet { if oldValue != revealed { relayout() } }
    }

    private var cards: [SidebarCard] = []
    private var views: [String: SidebarCardView] = [:]
    private var expanded = false
    /// Every card shows in a column (the pointer is over the stack).
    var isExpanded: Bool { expanded }
    private var observation: Task<Void, Never>?

    override var isFlipped: Bool { true }

    isolated deinit {
        observation?.cancel()
    }

    func follow(_ model: SidebarModel) {
        observation?.cancel()
        observation = Task { [weak self] in
            for await cards in Observations({ model.cards }) {
                self?.show(cards)
            }
        }
    }

    func show(_ next: [SidebarCard]) {
        guard next != cards else { return }
        cards = next
        let ids = Set(next.map(\.id))
        for (id, view) in views where !ids.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
        }
        for card in next {
            let view = views[card.id] ?? makeView(card.id)
            view.card = card
        }
        if next.isEmpty { expanded = false }
        relayout()
    }

    /// Side and vertical insets inside the full-width footer slot.
    private var inset: CGFloat { Metrics.space3 }
    private var gap: CGFloat { Metrics.space2 }

    /// Room the stack needs at `width` (0 without visible cards).
    func preferredHeight(width: CGFloat) -> CGFloat {
        let cards = placement(width: max(0, width - 2 * inset)).height
        return cards > 0 ? cards + 2 * gap : 0
    }

    /// The slot reads this: full width, the stack's height.
    override var fittingSize: NSSize {
        let width = superview?.bounds.width ?? bounds.width
        return NSSize(width: width, height: preferredHeight(width: width))
    }

    private var cardHeight: CGFloat {
        let tall = cards.contains { !$0.buttons.isEmpty || $0.progress != nil }
        return tall ? SidebarCardView.tallHeight : SidebarCardView.height
    }

    private func placement(width: CGFloat) -> SidebarCardStackLayout {
        SidebarCardStackLayout.layout(cards, revealed: revealed, expanded: expanded, width: width, cardHeight: cardHeight)
    }

    private func makeView(_ id: String) -> SidebarCardView {
        let view = SidebarCardView()
        view.onAction = { [weak self] action in self?.onAction?(id, action) }
        views[id] = view
        addSubview(view)
        return view
    }

    private func relayout() {
        onHeightChange?()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let layout = placement(width: max(0, bounds.width - 2 * inset))
        let placed = Dictionary(uniqueKeysWithValues: layout.placements.map { ($0.id, $0) })
        let animate = window != nil && Motion.animatesMovement
        for (id, view) in views {
            guard let place = placed[id] else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            view.isPeek = place.isPeek
            let frame = place.frame.offsetBy(dx: inset, dy: gap)
            if animate, view.frame != .zero {
                Motion.animate(.hover, in: view) { view.animator().frame = frame }
            } else {
                view.frame = frame
            }
        }
        // Front card on top: deeper cards are added below it.
        for place in layout.placements.reversed() {
            if let view = views[place.id] { addSubview(view, positioned: .above, relativeTo: nil) }
        }
    }

    // MARK: Hover expands

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setExpanded(true) }
    override func mouseExited(with event: NSEvent) { setExpanded(false) }

    private func setExpanded(_ value: Bool) {
        guard value != expanded, cards.count > 1 || !value else { return }
        expanded = value
        relayout()
    }
}
