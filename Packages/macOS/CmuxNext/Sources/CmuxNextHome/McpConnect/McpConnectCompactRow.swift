import AppKit

/// Style 1: one line (mark, "Connect X?", badge, Connect) with the facts behind Details.
struct McpConnectCompactRow {
    let parts: McpConnectParts

    @MainActor func make() -> NSView {
        let card = parts.card
        let flow = parts.flow
        var line: [NSView] = [parts.mark(size: 20),
                              parts.label(McpConnectStrings.connectTitle(card.title), font: parts.colors.emphasized, color: parts.colors.text),
                              parts.badge(), parts.spacer(min: 8)]
        if flow.phase == .ask {
            let state = parts.state
            line.append(parts.plainButton(McpConnectStrings.details, borderless: true) { state.open.toggle() })
            line.append(parts.dialogButton(McpConnectStrings.connect, id: "connect", hint: .return) { [actions = parts.actions] in actions.connect() })
        }
        var views: [NSView] = [parts.row(line, spacing: 8)]
        let open = parts.state.open
        if open || card.risky { views.append(parts.risks()) }
        if open {
            if let reason = parts.reason() { views.append(reason) }
            views += [parts.facts(), parts.scopeMenu()]
        }
        if flow.phase != .ask { views.append(parts.controls()) }
        return parts.column(views, spacing: 8)
    }
}
