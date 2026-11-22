import AppKit
import CmuxHomeCore
import CmuxNextActions
import CmuxNextHome

/// The Home page's compose-button menu. Each runs its catalog action
/// through the registry (the CLI and `cmux action run` reach the same
/// handler), so the menu adds no second code path.
@MainActor
enum HomePageMenus {
    /// The menu around the conversations: New Message, New Chief and Invite,
    /// each its catalog action (the toolbar's compose button runs New Message).
    static func backgroundMenu(registry: ActionRegistry) -> NSMenu {
        let menu = NSMenu()
        for (id, symbol): (ActionID, String) in [("home.newMessage", "square.and.pencil"), ("home.newChief", "sparkles"), ("home.invite", "envelope")] {
            guard let title = registry.descriptor(for: id)?.title else { continue }
            menu.addItem(HomeMenuTarget.item(title: title, symbol: symbol) {
                _ = registry.perform(id, invocation: ActionInvocation(origin: .user))
            })
        }
        return menu
    }
}

/// A menu item's closure, run by `HomeMenuTarget`.
final class HomeMenuRun: NSObject {
    let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
    }
}

/// The target of the Home page's closure menu items.
final class HomeMenuTarget: NSObject {
    static let shared = HomeMenuTarget()

    static func item(title: String, symbol: String, run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        item.target = shared
        item.representedObject = HomeMenuRun(run)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    @objc func fire(_ sender: NSMenuItem) { (sender.representedObject as? HomeMenuRun)?.run() }
}
