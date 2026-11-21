import SwiftUI

/// Styles 2 and 6: title and badge, the agent's reason, the facts table, the scope, the controls.
/// `riskFirst` (style 6) puts the risk lines above the title.
struct McpConnectFactsTableCard: View {
    let flow: McpConnectCardFlow
    let colors: McpConnectCardColors
    let actions: McpConnectCardActions
    let riskFirst: Bool

    var body: some View {
        let card = flow.card
        VStack(alignment: .leading, spacing: 10) {
            if riskFirst { McpConnectRiskLines(card: card, colors: colors) }
            HStack(spacing: 10) {
                McpConnectMark(title: card.title, size: 28, colors: colors)
                Text(McpConnectStrings.connectTitle(card.title)).font(colors.title).foregroundStyle(colors.text)
                Spacer(minLength: 8)
                McpConnectBadge(card: card, colors: colors)
            }
            McpConnectReason(card: card, colors: colors)
            McpConnectFacts(card: card, colors: colors)
            if flow.phase == .ask {
                HStack(spacing: 12) {
                    Text(McpConnectStrings.forScope).font(colors.caption).foregroundStyle(colors.tertiary)
                    McpConnectScopeMenu(flow: flow, colors: colors, actions: actions)
                }
            }
            if !riskFirst { McpConnectRiskLines(card: card, colors: colors) }
            McpConnectControls(flow: flow, colors: colors, actions: actions)
        }
    }
}

/// "Chief asks: …", the agent's own sentence in quotes.
struct McpConnectReason: View {
    let card: McpConnectCard
    let colors: McpConnectCardColors

    var body: some View {
        if !card.reason.isEmpty {
            (Text(McpConnectStrings.asks(card.agent) + " ").foregroundStyle(colors.tertiary)
                + Text("“" + card.reason + "”").foregroundStyle(colors.secondary))
                .font(colors.body)
        }
    }
}
