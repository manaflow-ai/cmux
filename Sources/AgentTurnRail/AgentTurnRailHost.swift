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

    init(model: AgentTurnRailModel, container: NSView) {
        self.model = model
        self.container = container
        railView = AgentTurnRailHostingView(rootView: AnyView(EmptyView()))
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

    /// Places the rail for the pane and returns the frame the terminal
    /// content should use.
    ///
    /// The rail goes in free space left of a width-limited session when that
    /// space is wide enough; otherwise it reserves a gutter by narrowing the
    /// terminal, so it never draws over terminal text.
    func layout(sessionFrame: CGRect, bounds: CGRect) -> CGRect {
        guard let container else { return sessionFrame }
        let shows = model.isVisible && sessionFrame.width >= Self.minimumContentWidth + Self.railWidth
        isShowingRail = shows
        guard shows else {
            railView.isHidden = true
            hideCard()
            return sessionFrame
        }
        mountIfNeeded(in: container)
        var contentFrame = sessionFrame
        let railFrame: CGRect
        if sessionFrame.minX - bounds.minX >= Self.railWidth {
            railFrame = CGRect(
                x: sessionFrame.minX - Self.railWidth,
                y: sessionFrame.minY,
                width: Self.railWidth,
                height: sessionFrame.height
            )
        } else {
            railFrame = CGRect(
                x: sessionFrame.minX,
                y: sessionFrame.minY,
                width: Self.railWidth,
                height: sessionFrame.height
            )
            contentFrame.origin.x += Self.railWidth
            contentFrame.size.width -= Self.railWidth
        }
        if railView.frame != railFrame { railView.frame = railFrame }
        railView.isHidden = false
        if hoveredIndex != nil { positionCard() }
        return contentFrame
    }

    /// Keeps the rail and card above views added after them.
    func bringToFront(in container: NSView) {
        guard isShowingRail else { return }
        if railView.superview === container {
            container.addSubview(railView, positioned: .above, relativeTo: nil)
        }
        if cardView.superview === container, !cardView.isHidden {
            container.addSubview(cardView, positioned: .above, relativeTo: nil)
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
        if cardView.superview !== container {
            container.addSubview(cardView, positioned: .above, relativeTo: nil)
        }
        let size = cardView.fittingSize
        let tickPoint = railView.convert(NSPoint(x: railView.bounds.maxX, y: hoveredTickY), to: container)
        let bounds = container.bounds
        var origin = NSPoint(x: tickPoint.x + Self.cardGap, y: tickPoint.y - size.height / 2)
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        origin.x = min(origin.x, max(bounds.minX, bounds.maxX - size.width))
        cardView.frame = CGRect(origin: origin, size: size)
        cardView.isHidden = false
        container.addSubview(cardView, positioned: .above, relativeTo: nil)
    }

    private func hideCard() {
        cardView.isHidden = true
    }

    private func select(index: Int) {
        hideCard()
        hoveredIndex = nil
        Task { @MainActor [model] in
            if await !model.jump(toEntryAt: index) {
                NSSound.beep()
            }
        }
    }
}
