public import SwiftUI

/// The MCP connect card in one of its looks (``McpConnectCardStyle``). Every look shows the same
/// facts and the same controls; only the arrangement differs.
public struct McpConnectCardView: View {
    let flow: McpConnectCardFlow
    let style: McpConnectCardStyle
    let colors: McpConnectCardColors
    let actions: McpConnectCardActions

    public init(flow: McpConnectCardFlow, style: McpConnectCardStyle, colors: McpConnectCardColors,
                actions: McpConnectCardActions) {
        self.flow = flow
        self.style = style
        self.colors = colors
        self.actions = actions
    }

    public var body: some View {
        content
            .padding(style == .compactRow ? 10 : 14)
            .frame(maxWidth: 520, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: style == .bubble ? 16 : 10, style: .continuous).fill(colors.surface))
            .overlay(RoundedRectangle(cornerRadius: style == .bubble ? 16 : 10, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1))
            .environment(\.colorScheme, colors.isDark ? .dark : .light)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(McpConnectStrings.connectTitle(flow.card.title))
    }

    private var borderColor: Color {
        style == .dangerForward && flow.card.risky ? colors.attention.opacity(0.6) : colors.separator
    }

    @ViewBuilder private var content: some View {
        switch style {
        case .compactRow: McpConnectCompactRow(flow: flow, colors: colors, actions: actions)
        case .factsTable: McpConnectFactsTableCard(flow: flow, colors: colors, actions: actions, riskFirst: false)
        case .permissionSheet: McpConnectPermissionSheet(flow: flow, colors: colors, actions: actions)
        case .twoStep: McpConnectTwoStep(flow: flow, colors: colors, actions: actions)
        case .bubble: McpConnectBubble(flow: flow, colors: colors, actions: actions)
        case .dangerForward: McpConnectFactsTableCard(flow: flow, colors: colors, actions: actions, riskFirst: true)
        }
    }
}
