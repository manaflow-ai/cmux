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
    private var pointerHover: PointerHover?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let hover = PointerHover(self) { [weak self] hovering in self?.setExpanded(hovering) }
        // The cards shown, not the slot: a stack whose cards hid is not hovered.
        hover.region = { view in
            view.subviews.reduce(CGRect.null) { $1 is SidebarCardView && !$1.isHidden ? $0.union($1.frame) : $0 }
        }
        pointerHover = hover
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
                Motion.animate(.hover, in: view, { view.animator().frame = frame }, completion: { [weak self] in
                    // The card ended its move under a possibly still pointer (cx-3wu5).
                    PointerHover.refresh(in: self?.window)
                })
            } else {
                view.frame = frame
            }
        }
        // Front card on top: deeper cards are added below it.
        for place in layout.placements.reversed() {
            if let view = views[place.id] { addSubview(view, positioned: .above, relativeTo: nil) }
        }
        // Cards moved or hid under a possibly still pointer (cx-3wu5).
        PointerHover.refresh(in: window)
    }

    // MARK: Hover expands


    private func setExpanded(_ value: Bool) {
        guard value != expanded, cards.count > 1 || !value else { return }
        expanded = value
        relayout()
    }
}
