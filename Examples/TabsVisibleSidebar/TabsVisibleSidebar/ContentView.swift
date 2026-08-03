import AppKit

@MainActor
final class ContentViewController: NSViewController {
    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let icon = NSImageView(image: NSImage(
            systemSymbolName: "sidebar.leading",
            accessibilityDescription: String(localized: "tabsVisible.app.title", defaultValue: "Tabs Visible Sidebar")
        ) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label(
            String(localized: "tabsVisible.app.title", defaultValue: "Tabs Visible Sidebar"),
            font: .systemFont(ofSize: 17, weight: .semibold),
            color: .labelColor
        ))
        stack.addArrangedSubview(label(
            String(
                localized: "tabsVisible.app.detail",
                defaultValue: "Keep this app installed. Enable Tabs Visible Sidebar from cmux Sidebar Extensions, then choose the extension sidebar provider from the sidebar footer puzzle button."
            ),
            font: .systemFont(ofSize: 13),
            color: .secondaryLabelColor
        ))
        stack.addArrangedSubview(label(
            String(
                localized: "tabsVisible.app.scopes",
                defaultValue: "The extension shows workspaces as disclosure groups and lists each workspace surface underneath."
            ),
            font: .systemFont(ofSize: 11),
            color: .secondaryLabelColor
        ))

        view = stack
        view.widthAnchor.constraint(equalToConstant: 420).isActive = true
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = 0
        return field
    }
}
