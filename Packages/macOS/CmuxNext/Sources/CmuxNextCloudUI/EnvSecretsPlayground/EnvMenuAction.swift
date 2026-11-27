#if DEBUG
import AppKit

/// DEBUG ONLY (Environment Secrets Playground): the target of a menu item that runs a closure. The item
/// keeps it alive as its represented object.
final class EnvMenuAction: NSObject {
    private let onPick: @MainActor () -> Void

    private init(_ onPick: @escaping @MainActor () -> Void) { self.onPick = onPick }

    /// A menu item titled `title` (with an SF Symbol when given) that runs `onPick` when picked.
    static func item(_ title: String, symbol: String? = nil, onPick: @escaping @MainActor () -> Void) -> NSMenuItem {
        let action = EnvMenuAction(onPick)
        let item = NSMenuItem(title: title, action: #selector(pick), keyEquivalent: "")
        item.target = action
        item.representedObject = action
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func pick() { onPick() }
}
#endif
