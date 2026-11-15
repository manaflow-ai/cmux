import AppKit

/// Style 3: a big mark over "Connect X?", the access as bullets, then the server and the controls.
struct McpConnectPermissionSheet {
    let parts: McpConnectParts

    @MainActor func make() -> NSView {
        let card = parts.card
        let colors = parts.colors
        var centered: [NSView] = [parts.mark(size: 44),
                                  parts.label(McpConnectStrings.connectTitle(card.title), font: colors.title, color: colors.text),
                                  parts.badge()]
        let reason = parts.reason(centered: true)
        if let reason { centered.append(reason) }
        let bullets = parts.column(lines(card).map { line in
            parts.row([parts.symbol("circle.fill", color: colors.tertiary, size: colors.caption.pointSize * 0.4),
                       parts.label(line, font: colors.body, color: colors.text, lines: 0)], spacing: 8, alignment: .centerY)
        }, spacing: 4)
        var leading: [NSView] = [bullets, parts.facts(), parts.risks()]
        if parts.flow.phase == .ask { leading.append(parts.scopeMenu()) }
        let stack = parts.column(centered, spacing: 10, alignment: .centerX, fill: false)
        // The reason wraps at the card's width, centered.
        reason?.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for view in leading { stack.addArrangedSubview(view) }
        let controls = parts.controls()
        stack.addArrangedSubview(controls)
        // The bullets, facts, risks and controls run the card's width from its leading edge.
        for view in leading + [controls] where !(view is NSPopUpButton) {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func lines(_ card: McpConnectCard) -> [String] {
        card.scopes.isEmpty ? [McpConnectAccessText(card: card).text] : card.scopes
    }
}
