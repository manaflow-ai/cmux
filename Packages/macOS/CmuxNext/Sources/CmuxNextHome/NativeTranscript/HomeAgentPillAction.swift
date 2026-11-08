import AppKit

/// The Objective-C target that runs a closure for an agent pill's Start now (its card's button and its menu
/// item); the control or item keeps it alive.
@MainActor
final class HomeAgentPillAction: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run() { handler() }

    /// A context-menu item titled `title` with SF Symbol `symbol` that runs `handler`.
    static func item(_ title: String, symbol: String, handler: @escaping () -> Void) -> NSMenuItem {
        let action = HomeAgentPillAction(handler: handler)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }
}
