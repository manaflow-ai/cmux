import SwiftUI

/// Style 5: the card reads as the agent's message: its sentence first, then the facts small, then
/// the buttons inside the bubble.
struct McpConnectBubble: View {
    let flow: McpConnectCardFlow
    let colors: McpConnectCardColors
    let actions: McpConnectCardActions

    var body: some View {
        let card = flow.card
        VStack(alignment: .leading, spacing: 8) {
            Text(McpConnectStrings.connectTitle(card.title)).font(colors.emphasized).foregroundStyle(colors.text)
            if !card.reason.isEmpty {
                Text(card.reason).font(colors.body).foregroundStyle(colors.secondary)
            }
            HStack(spacing: 6) {
                McpConnectBadge(card: card, colors: colors)
                Text("·").foregroundStyle(colors.tertiary)
                Text(McpConnectAccessText(card: card).text).font(colors.caption).foregroundStyle(colors.tertiary)
            }
            McpConnectFacts(card: card, colors: colors)
            McpConnectRiskLines(card: card, colors: colors)
            if flow.phase == .ask { McpConnectScopeMenu(flow: flow, colors: colors, actions: actions) }
            McpConnectControls(flow: flow, colors: colors, actions: actions)
        }
    }
}
