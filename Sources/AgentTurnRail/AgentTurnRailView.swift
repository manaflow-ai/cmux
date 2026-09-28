import AppKit
import CmuxAgentChat
import CmuxFoundation
import SwiftUI

/// The thin tick rail at a terminal pane's leading edge: one tick per prompt,
/// the turn on screen drawn longer in the cmux accent.
struct AgentTurnRailView: View {
    let model: AgentTurnRailModel
    /// Reports the hovered turn and its tick's y in the rail's coordinates
    /// (top origin), or `nil` when the pointer leaves the ticks.
    let onHover: (_ index: Int?, _ tickY: CGFloat) -> Void
    let onSelect: (_ index: Int) -> Void

    @Environment(\.cmuxAccentColor) private var cmuxAccent
    @State private var hoveredIndex: Int?
    @State private var tickColor = Color(nsColor: GhosttyApp.shared.defaultForegroundColor)

    static let restingTickWidth: CGFloat = 5
    static let emphasizedTickWidth: CGFloat = 10
    static let leadingInset: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let layout = ChatOutlineRailLayout(count: model.entries.count, height: proxy.size.height)
            // Read observable state here, in body, so changes redraw the
            // canvas; the renderer closure runs outside observation tracking.
            let ticks = TickState(
                current: model.currentIndex,
                hovered: hoveredIndex,
                jumpable: model.entries.indices.map { !model.hasResolvedAnchors || model.isJumpable($0) },
                accent: cmuxAccent.color,
                base: tickColor
            )
            Canvas { context, _ in
                Self.drawTicks(in: &context, layout: layout, state: ticks)
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    let index = layout.index(atY: location.y)
                    if index != hoveredIndex { hoveredIndex = index }
                    onHover(index, index.map { CGFloat(layout.y(for: $0)) } ?? 0)
                case .ended:
                    hoveredIndex = nil
                    onHover(nil, 0)
                }
            }
            .gesture(
                SpatialTapGesture(coordinateSpace: .local).onEnded { value in
                    guard let index = layout.index(atY: value.location.y) else { return }
                    onSelect(index)
                }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(String(localized: "agentTurnRail.accessibilityLabel", defaultValue: "Agent turns")))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAdjustableAction { direction in
            Task { @MainActor in
                switch direction {
                case .increment:
                    await model.jumpToNextTurn()
                case .decrement:
                    await model.jumpToPreviousTurn()
                @unknown default:
                    break
                }
            }
        }
        .accessibilityIdentifier("AgentTurnRail")
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
            tickColor = Color(nsColor: GhosttyApp.shared.defaultForegroundColor)
        }
    }

    /// The prompt of the turn on screen.
    private var accessibilityValue: String {
        guard let current = model.currentIndex, model.entries.indices.contains(current) else {
            return ""
        }
        return model.entries[current].title
    }

    private struct TickState {
        let current: Int?
        let hovered: Int?
        let jumpable: [Bool]
        let accent: Color
        let base: Color
    }

    private static func drawTicks(in context: inout GraphicsContext, layout: ChatOutlineRailLayout, state: TickState) {
        for index in layout.drawnIndices(highlighted: state.current ?? state.hovered) {
            let isCurrent = index == state.current
            let isHovered = index == state.hovered
            let isJumpable = state.jumpable.indices.contains(index) ? state.jumpable[index] : true
            let width = (isCurrent || isHovered) ? emphasizedTickWidth : restingTickWidth
            let height: CGFloat = isCurrent ? 2 : 1.5
            let y = CGFloat(layout.y(for: index))
            let rect = CGRect(x: leadingInset, y: y - height / 2, width: width, height: height)
            let color: Color
            if isCurrent {
                color = state.accent
            } else if isHovered {
                color = state.base.opacity(isJumpable ? 0.9 : 0.45)
            } else {
                color = state.base.opacity(isJumpable ? 0.38 : 0.14)
            }
            context.fill(Path(roundedRect: rect, cornerRadius: height / 2), with: .color(color))
        }
    }
}

/// The floating card shown beside a hovered tick.
struct AgentTurnHoverCard: View {
    let entry: ChatOutlineEntry
    let isJumpable: Bool

    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if let reply = entry.replyPreview {
                Text(reply)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            if !isJumpable {
                Text(String(
                    localized: "agentTurnRail.notInScrollback",
                    defaultValue: "No longer in scrollback"
                ))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
        .frame(width: Self.width - 20, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(8)
        .accessibilityIdentifier("AgentTurnHoverCard")
    }
}

/// Rail host that takes clicks and hover.
final class AgentTurnRailHostingView: NSHostingView<AnyView> {
    /// Receives scrolling over the rail, so the gutter scrolls the terminal
    /// like the rest of the pane.
    weak var scrollTarget: NSView?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard let scrollTarget else {
            super.scrollWheel(with: event)
            return
        }
        scrollTarget.scrollWheel(with: event)
    }
}

/// Card host that never takes pointer events, so the terminal under it keeps
/// working while the card is up.
final class AgentTurnHoverCardHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
