import AppKit
import CmuxNextDesign

/// The home page's building blocks: a titled group card, a switch row and a
/// permission row, in the page's colors.
@MainActor
enum MacScreenHomeParts {
    /// A titled group card: the title over a rounded card (a tint, a hairline
    /// border while `appearance.borders` is on) that holds `content` edge to edge.
    static func section(_ title: String, content: NSView) -> NSView {
        let card = MacScreenFill(\.card, shape: .rounded(Metrics.panelCornerRadius), bordered: true)
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        let column = MacScreenStack.make(.vertical, spacing: 8, alignment: .leading)
        column.addArrangedSubview(MacScreenText(title, font: MacScreenType.header, ink: \.secondary))
        MacScreenStack.addFullWidth(card, to: column)
        return column
    }

    /// The card's padded column (`VStack(spacing: 12).padding(14)`).
    static func cardColumn() -> NSStackView {
        MacScreenStack.make(.vertical, spacing: 12, alignment: .leading, insets: NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14))
    }

    /// A note in the secondary ink, padded, as wide as its card.
    static func note(_ text: String) -> NSView {
        let column = cardColumn()
        MacScreenStack.addFullWidth(MacScreenText(text, font: MacScreenType.body, ink: \.secondary, wraps: true), to: column)
        return column
    }

    /// A switch with its title and detail before it: the label leads, the switch trails.
    static func switchRow(title: String, detail: String, isOn: Bool, enabled: Bool = true, id: String,
                          change: @escaping (Bool) -> Void) -> NSView {
        let labels = MacScreenStack.make(.vertical, spacing: 2, alignment: .leading)
        MacScreenStack.addFullWidth(MacScreenText(title, font: MacScreenType.body, wraps: true), to: labels)
        MacScreenStack.addFullWidth(MacScreenText(detail, font: MacScreenType.caption, ink: \.secondary, wraps: true), to: labels)
        let toggle = MacScreenSwitch(id: id, label: title)
        toggle.isOn = isOn
        toggle.isEnabled = enabled
        toggle.onChange = change
        let row = MacScreenStack.make(.horizontal, spacing: 8, alignment: .centerY, [labels, toggle])
        labels.setContentHuggingPriority(.init(1), for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    /// A permission's row: granted, or a button that opens its System Settings pane.
    static func permissionRow(title: String, detail: String, granted: Bool, action: String? = nil, id: String? = nil,
                              open: @escaping () -> Void) -> NSView {
        let glyph = MacScreenGlyph(granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill", font: MacScreenType.body,
                                   ink: granted ? \.success : \.attention)
        let labels = MacScreenStack.make(.vertical, spacing: 2, alignment: .leading)
        MacScreenStack.addFullWidth(MacScreenText(title, font: MacScreenType.emphasized, wraps: true), to: labels)
        MacScreenStack.addFullWidth(MacScreenText(detail, font: MacScreenType.caption, ink: \.secondary, wraps: true), to: labels)
        labels.setContentHuggingPriority(.init(1), for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let trailing: NSView = granted
            ? MacScreenText(L.t("macScreen.home.granted", "Allowed"), font: MacScreenType.caption, ink: \.secondary)
            : MacScreenButton(action ?? L.t("macScreen.home.openSettings", "Open System Settings"), compact: true, action: open)
        let row = MacScreenStack.make(.horizontal, spacing: 10, alignment: .top, [glyph, labels, trailing])
        if let id { row.setAccessibilityIdentifier(id) }
        return row
    }
}
