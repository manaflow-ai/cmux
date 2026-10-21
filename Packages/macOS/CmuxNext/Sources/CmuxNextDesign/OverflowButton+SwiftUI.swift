public import AppKit
public import SwiftUI

/// A SwiftUI page's more button: the app's one ``OverflowButton`` (⋮, its glyph, hit target and
/// hover), whose menu opens on press like the sidebar's and the pane toolbar's. The rows are
/// AppKit's, themed in the button's scope (`themeRows`).
public struct OverflowMenuButton: NSViewRepresentable {
    /// One row of the menu, or a separator.
    public enum Item {
        case action(String, @MainActor () -> Void)
        case separator
    }

    /// The side of the square hit target, the sidebar row's control (`SidebarStyle.controlSize`).
    public static var side: CGFloat { Metrics.iconSize + Metrics.space2 }

    private let label: String
    private let identifier: String?
    private let items: [Item]

    /// - Parameters:
    ///   - label: What the menu holds, for VoiceOver and the tooltip.
    ///   - identifier: The button's accessibility identifier.
    ///   - items: The menu's rows, in order, read when it opens.
    public init(label: String, identifier: String? = nil, items: [Item]) {
        self.label = label
        self.identifier = identifier
        self.items = items
    }

    public func makeCoordinator() -> OverflowMenuTarget { OverflowMenuTarget() }

    public func makeNSView(context: Context) -> OverflowButton {
        let button = OverflowButton(label: label)
        let target = context.coordinator
        button.pressMenu = { [weak button] in button.map { target.menu(in: $0.themeScope.fullStrength) } }
        return button
    }

    public func updateNSView(_ button: OverflowButton, context: Context) {
        context.coordinator.items = items
        button.label = label
        if let identifier, button.accessibilityIdentifier() != identifier { button.setAccessibilityIdentifier(identifier) }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: OverflowButton, context: Context) -> CGSize? {
        CGSize(width: Self.side, height: Self.side)
    }
}

/// Builds an `OverflowMenuButton`'s menu and runs the chosen row. Not nested in the representable,
/// like `ThemedPickerTarget`.
@MainActor public final class OverflowMenuTarget: NSObject {
    var items: [OverflowMenuButton.Item] = []

    func menu(in scope: ThemeScope) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, item) in items.enumerated() {
            switch item {
            case .separator:
                menu.addItem(.separator())
            case let .action(title, _):
                let row = NSMenuItem(title: title, action: #selector(chose(_:)), keyEquivalent: "")
                row.target = self
                row.tag = index
                menu.addItem(row)
            }
        }
        return menu.themeRows(in: scope)
    }

    @objc private func chose(_ row: NSMenuItem) {
        guard items.indices.contains(row.tag), case let .action(_, run) = items[row.tag] else { return }
        run()
    }
}
