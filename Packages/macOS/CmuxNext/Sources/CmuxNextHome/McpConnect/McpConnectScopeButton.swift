import AppKit

/// Who gets the server: a borderless pull-down whose title is the chosen scope and whose items are
/// every scope.
@MainActor
final class McpConnectScopeButton: NSPopUpButton {
    private let choose: @MainActor (McpConnectCard.Scope) -> Void

    init(scope: McpConnectCard.Scope, colors: McpConnectCardColors, choose: @escaping @MainActor (McpConnectCard.Scope) -> Void) {
        self.choose = choose
        super.init(frame: .zero, pullsDown: true)
        isBordered = false
        font = colors.body
        contentTintColor = colors.text
        // A pull-down shows its first item as its title.
        addItem(withTitle: McpConnectStrings.scope(scope))
        for option in McpConnectCard.Scope.allCases {
            let item = NSMenuItem(title: McpConnectStrings.scope(option), action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            menu?.addItem(item)
        }
        setAccessibilityIdentifier("cmux.home.mcpConnect.scope")
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Picks `scope`, as choosing its menu item does.
    func pick(_ scope: McpConnectCard.Scope) { choose(scope) }

    @objc private func picked(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let scope = McpConnectCard.Scope(rawValue: raw) else { return }
        choose(scope)
    }
}
