import AppKit
import CmuxNextActions
import CmuxNextHome

/// The Home page list's right-click items. Each runs its catalog action
/// through the registry (the CLI and `cmux action run` reach the same
/// handler), so the menu adds no second code path.
@MainActor
enum HomePageMenus {
    /// Archive Chief for one of my cloud Chiefs that is not the default.
    static func chiefMenu(chief: String, registry: ActionRegistry) -> NSMenu {
        let menu = NSMenu()
        let item = HomeMenuTarget.item(title: HomeConversationStrings.archiveChief, symbol: "archivebox") {
            _ = registry.perform("home.archiveChief", invocation: ActionInvocation(arguments: ["chief": .string(chief)], origin: .user))
        }
        menu.addItem(item)
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
