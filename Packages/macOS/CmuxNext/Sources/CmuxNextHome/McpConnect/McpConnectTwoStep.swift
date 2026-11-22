import CmuxNextDesign
import SwiftUI

/// Style 4: first "X wants to connect" with Review; Review shows the facts and Connect.
struct McpConnectTwoStep: View {
    let flow: McpConnectCardFlow
    let colors: McpConnectCardColors
    let actions: McpConnectCardActions
    @State private var reviewing = false

    var body: some View {
        if reviewing || flow.phase != .ask {
            McpConnectFactsTableCard(flow: flow, colors: colors, actions: actions, riskFirst: flow.card.risky)
        } else {
            HStack(spacing: 10) {
                McpConnectMark(title: flow.card.title, size: 28, colors: colors)
                VStack(alignment: .leading, spacing: 2) {
                    Text(McpConnectStrings.wantsAccess(flow.card.agent + " · " + flow.card.title))
                        .font(colors.emphasized).foregroundStyle(colors.text)
                    McpConnectBadge(card: flow.card, colors: colors)
                }
                Spacer(minLength: 8)
                CmuxDialogActionButton(McpConnectStrings.cancel, hint: .escape, action: actions.cancel)
                CmuxDialogActionButton(McpConnectStrings.review, hint: .return) { reviewing = true }
            }
        }
    }
}
