public import AppKit
import CmuxNextDesign

/// The MCP connect card in one of its looks (``McpConnectCardStyle``). Every look shows the same
/// facts and the same controls; only the arrangement differs.
///
/// AppKit (plans/cmux-next/no-swiftui-DESIGN.md): the card draws its look from a value flow; the
/// host gives it a new flow with ``show(_:)``. The card keeps its own small state (an open Details,
/// Review taken, the typed key) across draws of the same card.
public final class McpConnectCardView: NSView {
    /// The flow the card shows.
    public private(set) var flow: McpConnectCardFlow
    /// The look.
    public let style: McpConnectCardStyle
    private let colors: McpConnectCardColors
    private let actions: McpConnectCardActions
    private let state = McpConnectCardState()
    private var content: NSView?

    /// The card's widest width.
    static let maxWidth: CGFloat = 520

    public init(flow: McpConnectCardFlow, style: McpConnectCardStyle, colors: McpConnectCardColors,
                actions: McpConnectCardActions) {
        self.flow = flow
        self.style = style
        self.colors = colors
        self.actions = actions
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        appearance = colors.appearance
        wantsLayer = true
        let radius = style == .bubble ? 16 : Metrics.surfaceCornerRadius
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.backgroundColor = colors.surface.cgColor
        widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        state.changed = { [weak self] in self?.draw() }
        draw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `flow`, the same card one step on.
    public func show(_ flow: McpConnectCardFlow) {
        guard flow != self.flow else { return }
        self.flow = flow
        draw()
    }

    /// Draws the card's look for its flow and state.
    private func draw() {
        let border = style == .dangerForward && flow.card.risky ? colors.attention.withAlphaComponent(0.6) : colors.separator
        layer?.borderColor = border.cgColor
        setAccessibilityLabel(McpConnectStrings.connectTitle(flow.card.title))
        state.releaseHeld()
        content?.removeFromSuperview()
        let parts = McpConnectParts(flow: flow, colors: colors, actions: actions, state: state)
        let view: NSView = switch style {
        case .compactRow: McpConnectCompactRow(parts: parts).make()
        case .factsTable: McpConnectFactsTableCard(parts: parts, riskFirst: false).make()
        case .permissionSheet: McpConnectPermissionSheet(parts: parts).make()
        case .twoStep: McpConnectTwoStep(parts: parts).make()
        case .bubble: McpConnectBubble(parts: parts).make()
        case .dangerForward: McpConnectFactsTableCard(parts: parts, riskFirst: true).make()
        }
        let padding: CGFloat = style == .compactRow ? 10 : 14
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            view.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
        content = view
    }
}
