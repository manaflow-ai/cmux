import AppKit

/// Style 5: the card reads as the agent's message: its sentence first, then the facts small, then
/// the buttons inside the bubble.
struct McpConnectBubble {
    let parts: McpConnectParts

    @MainActor func make() -> NSView {
        let card = parts.card
        let colors = parts.colors
        var views: [NSView] = [parts.label(McpConnectStrings.connectTitle(card.title), font: colors.emphasized, color: colors.text)]
        if !card.reason.isEmpty { views.append(parts.label(card.reason, font: colors.body, color: colors.secondary, lines: 0)) }
        views.append(parts.row([parts.badge(), parts.label("·", font: colors.body, color: colors.tertiary),
                                parts.label(McpConnectAccessText(card: card).text, font: colors.caption, color: colors.tertiary)],
                               spacing: 6))
        views += [parts.facts(), parts.risks()]
        if parts.flow.phase == .ask { views.append(parts.scopeMenu()) }
        views.append(parts.controls())
        return parts.column(views, spacing: 8)
    }
}
