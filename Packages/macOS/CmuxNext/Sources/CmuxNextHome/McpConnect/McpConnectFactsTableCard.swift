import AppKit

/// Styles 2 and 6: title and badge, the agent's reason, the facts table, the scope, the controls.
/// `riskFirst` (style 6) puts the risk lines above the title.
struct McpConnectFactsTableCard {
    let parts: McpConnectParts
    let riskFirst: Bool

    @MainActor func make() -> NSView {
        let card = parts.card
        let colors = parts.colors
        var views: [NSView] = []
        if riskFirst { views.append(parts.risks()) }
        views.append(parts.row([parts.mark(size: 28),
                                parts.label(McpConnectStrings.connectTitle(card.title), font: colors.title, color: colors.text),
                                parts.spacer(min: 8), parts.badge()], spacing: 10))
        if let reason = parts.reason() { views.append(reason) }
        views.append(parts.facts())
        if parts.flow.phase == .ask {
            views.append(parts.row([parts.label(McpConnectStrings.forScope, font: colors.caption, color: colors.tertiary),
                                    parts.scopeMenu()], spacing: 12))
        }
        if !riskFirst { views.append(parts.risks()) }
        views.append(parts.controls())
        return parts.column(views, spacing: 10)
    }
}
