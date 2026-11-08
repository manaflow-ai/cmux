import CmuxNextDesign
import SwiftUI

/// Style 1: one line (mark, "Connect X?", badge, Connect) with the facts behind Details.
struct McpConnectCompactRow: View {
    let flow: McpConnectCardFlow
    let colors: McpConnectCardColors
    let actions: McpConnectCardActions
    @State private var open = false

    var body: some View {
        let card = flow.card
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                McpConnectMark(title: card.title, size: 20, colors: colors)
                Text(McpConnectStrings.connectTitle(card.title)).font(colors.emphasized).foregroundStyle(colors.text)
                McpConnectBadge(card: card, colors: colors)
                Spacer(minLength: 8)
                if flow.phase == .ask {
                    Button(McpConnectStrings.details) { open.toggle() }.buttonStyle(.borderless)
                    CmuxDialogActionButton(McpConnectStrings.connect, hint: .return, action: actions.connect)
                }
            }
            if open || card.risky {
                McpConnectRiskLines(card: card, colors: colors)
            }
            if open {
                McpConnectReason(card: card, colors: colors)
                McpConnectFacts(card: card, colors: colors)
                McpConnectScopeMenu(flow: flow, colors: colors, actions: actions)
            }
            if flow.phase != .ask {
                McpConnectControls(flow: flow, colors: colors, actions: actions)
            }
        }
    }
}
