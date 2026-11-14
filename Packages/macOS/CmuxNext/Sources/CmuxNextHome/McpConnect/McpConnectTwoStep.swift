import AppKit

/// Style 4: first "X wants to connect" with Review; Review shows the facts and Connect.
struct McpConnectTwoStep {
    let parts: McpConnectParts

    @MainActor func make() -> NSView {
        let card = parts.card
        if parts.state.reviewing || parts.flow.phase != .ask {
            return McpConnectFactsTableCard(parts: parts, riskFirst: card.risky).make()
        }
        let colors = parts.colors
        let state = parts.state
        let text = parts.column([parts.label(McpConnectStrings.wantsAccess(card.agent + " · " + card.title), font: colors.emphasized,
                                             color: colors.text),
                                 parts.badge()], spacing: 2)
        return parts.row([parts.mark(size: 28), text, parts.spacer(min: 8),
                          parts.dialogButton(McpConnectStrings.cancel, id: "cancel", hint: .escape) { [actions = parts.actions] in actions.cancel() },
                          parts.dialogButton(McpConnectStrings.review, id: "review", hint: .return) { state.reviewing = true }],
                         spacing: 10)
    }
}
