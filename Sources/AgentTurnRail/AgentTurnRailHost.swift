import AppKit
import CmuxAgentChat
import SwiftUI

/// Mounts one terminal's turn rail and hover card inside its
/// `GhosttySurfaceScrollView` (the AppKit portal layer, where terminal
/// overlays must live), and decides the rail's gutter.
@MainActor
final class AgentTurnRailHost {
    /// Width of the rail gutter.
    static let railWidth: CGFloat = 16
    /// Narrowest terminal content width that still gets a rail.
    static let minimumContentWidth: CGFloat = 240
    private static let cardGap: CGFloat = 2

    let model: AgentTurnRailModel
    private weak var container: NSView?
    private let railView: AgentTurnRailHostingView
    private let cardView: AgentTurnHoverCardHostingView
    private var hoveredIndex: Int?
    private var hoveredTickY: CGFloat = 0

    init(model: AgentTurnRailModel, container: NSView, scrollTarget: NSView?) {
        self.model = model
        self.container = container
        railView = AgentTurnRailHostingView(rootView: AnyView(EmptyView()))
        railView.scrollTarget = scrollTarget
        cardView = AgentTurnHoverCardHostingView(rootView: AnyView(EmptyView()))
        railView.isHidden = true
        cardView.isHidden = true
        railView.setAccessibilityIdentifier("AgentTurnRailHost")
        railView.rootView = AnyView(
            AgentTurnRailView(
                model: model,
                onHover: { [weak self] index, tickY in self?.hover(index: index, tickY: tickY) },
                onSelect: { [weak self] index in self?.select(index: index) }
            )
            .cmuxAccentColorEnvironment()
        )
    }

    /// Whether the rail currently occupies a gutter.
    private(set) var isShowingRail = false

    /// Where the rail and the terminal content go for a pane.
    ///
    /// The rail goes in free space left of a width-limited session when that
    /// space is wide enough; otherwise it reserves a gutter by narrowing the
    /// terminal, so it never draws over terminal text. The gutter is kept for
    /// the whole live agent session so the rail appearing or disappearing
    /// never reflows the agent's interface.
    ///
    /// - Returns: `nil` when the pane keeps its full width and has no rail.
    func placement(sessionFrame: CGRect, bounds: CGRect) -> (rail: CGRect, content: CGRect)? {
        guard model.reservesGutter,
              sessionFrame.width >= Self.minimumContentWidth + Self.railWidth else {
            return nil
        }
        if sessionFrame.minX - bounds.minX >= Self.railWidth {
            let rail = CGRect(
                x: sessionFrame.minX - Self.railWidth,
                y: sessionFrame.minY,
                width: Self.railWidth,
                height: sessionFrame.height
            )
            return (rail, sessionFrame)
        }
        let rail = CGRect(x: sessionFrame.minX, y: sessionFrame.minY, width: Self.railWidth, height: sessionFrame.height)
        var content = sessionFrame
        content.origin.x += Self.railWidth
        content.size.width -= Self.railWidth
        return (rail, content)
    }

    /// Terminal content frame for `sessionFrame`, without side effects. Other
    /// overlays that cover the terminal use this so they stay off the rail.
    func contentFrame(sessionFrame: CGRect, bounds: CGRect) -> CGRect {
        placement(sessionFrame: sessionFrame, bounds: bounds)?.content ?? sessionFrame
    }

    /// Places the rail for the pane and returns the frame the terminal
    /// content should use.
    func layout(sessionFrame: CGRect, bounds: CGRect) -> CGRect {
        guard let container, let placement = placement(sessionFrame: sessionFrame, bounds: bounds) else {
            isShowingRail = false
            railView.isHidden = true
            hideCard()
            return sessionFrame
        }
        isShowingRail = true
        mountIfNeeded(in: container)
        if railView.frame != placement.rail { railView.frame = placement.rail }
        // The gutter is reserved as soon as an agent session attaches; ticks
        // appear with the second prompt.
        railView.isHidden = !model.isVisible
        if !model.isVisible {
            hoveredIndex = nil
            hideCard()
        } else if hoveredIndex != nil {
            positionCard()
        }
        // A pane coming on screen resolves anchors it deferred while hidden.
        model.resumeDeferredResolve()
        return placement.content
    }

    /// Keeps the rail and card above views added after them, without
    /// reordering subviews when they already are on top.
    func bringToFront(in container: NSView) {
        guard isShowingRail else { return }
        var wanted: [NSView] = []
        if railView.superview === container { wanted.append(railView) }
        if cardView.superview === container, !cardView.isHidden { wanted.append(cardView) }
        guard !container.subviews.suffix(wanted.count).elementsEqual(wanted, by: ===) else { return }
        for view in wanted {
            container.addSubview(view, positioned: .above, relativeTo: nil)
        }
    }

    func tearDown() {
        railView.removeFromSuperview()
        cardView.removeFromSuperview()
        model.stop()
    }

    private func mountIfNeeded(in container: NSView) {
        if railView.superview !== container {
            railView.removeFromSuperview()
            container.addSubview(railView, positioned: .above, relativeTo: nil)
        }
    }

    // MARK: - Hover card

    private func hover(index: Int?, tickY: CGFloat) {
        guard let index, model.entries.indices.contains(index) else {
            hoveredIndex = nil
            hideCard()
            return
        }
        let changed = index != hoveredIndex
        hoveredIndex = index
        hoveredTickY = tickY
        if changed || cardView.isHidden {
            cardView.rootView = AnyView(
                AgentTurnHoverCard(entry: model.entries[index], isJumpable: model.isJumpable(index))
            )
        }
        positionCard()
    }

    private func positionCard() {
        guard let container, let index = hoveredIndex, model.entries.indices.contains(index) else {
            hideCard()
            return
        }
        if cardView.superview !== container || container.subviews.last !== cardView {
            container.addSubview(cardView, positioned: .above, relativeTo: nil)
        }
        let size = cardView.fittingSize
        let tickPoint = railView.convert(NSPoint(x: railView.bounds.maxX, y: hoveredTickY), to: container)
        let bounds = container.bounds
        var origin = NSPoint(x: tickPoint.x + Self.cardGap, y: tickPoint.y - size.height / 2)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        origin.x = min(origin.x, max(bounds.minX, bounds.maxX - size.width))
        let frame = CGRect(origin: origin, size: size)
        if cardView.frame != frame { cardView.frame = frame }
        cardView.isHidden = false
    }

    private func hideCard() {
        cardView.isHidden = true
    }

    private func select(index: Int) {
        hideCard()
        hoveredIndex = nil
        guard model.entries.indices.contains(index) else { return }
        // Capture the entry now: the outline can grow before the jump runs.
        let id = model.entries[index].id
        Task { @MainActor [model] in
            if await !model.jump(toEntryID: id) {
                NSSound.beep()
            }
        }
    }
}
