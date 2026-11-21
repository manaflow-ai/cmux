public import AppKit

/// The Dock menu's `NSMenu` from ready values: no store, socket or disk read. Our rows come
/// first; macOS adds Options, Show All Windows, Hide and Quit under them. Section titles are
/// disabled header rows, as Codex's Dock menu shows Unread and Recent.
@MainActor
enum DockMenuBuilder {
    /// The action a row carries (`NSMenuItem.representedObject`).
    final class Box: NSObject {
        let action: DockMenuAction
        init(_ action: DockMenuAction) { self.action = action }
    }

    static func menu(chats: DockMenuChats, choices: DockMenuChoices, target: AnyObject?, action: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func row(_ title: String, _ value: DockMenuAction) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = Box(value)
            return item
        }
        func chatRow(_ chat: DockMenuChats.Chat) -> NSMenuItem { row(chat.title, .open(chat: chat.id)) }
        func section(_ title: String, _ shown: [DockMenuChats.Chat], _ more: [DockMenuChats.Chat]) {
            guard !shown.isEmpty else { return }
            menu.addItem(.separator())
            menu.addItem(header(title))
            for chat in shown { menu.addItem(chatRow(chat)) }
            guard !more.isEmpty else { return }
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for chat in more { submenu.addItem(chatRow(chat)) }
            let item = NSMenuItem(title: DockMenuStrings.more, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }

        menu.addItem(row(DockMenuStrings.newChat, .newChat(harness: nil, machine: nil)))
        if !choices.harnesses.isEmpty || !choices.machines.isEmpty {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for harness in choices.harnesses { submenu.addItem(row(harness.title, .newChat(harness: harness.id, machine: nil))) }
            if !choices.machines.isEmpty {
                if !choices.harnesses.isEmpty { submenu.addItem(.separator()) }
                for machine in choices.machines { submenu.addItem(row(machine.title, .newChat(harness: nil, machine: machine.id))) }
            }
            let item = NSMenuItem(title: DockMenuStrings.newChatIn, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        if let last = chats.last { menu.addItem(row(DockMenuStrings.continueChat(last.title), .open(chat: last.id))) }
        section(DockMenuStrings.unread, chats.unread, chats.unreadMore)
        section(DockMenuStrings.recent, chats.recent, chats.recentMore)
        return menu
    }

    /// A section title: a disabled row, like Codex's "Unread" and "Recent".
    private static func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// The Dock menu's words (Resources/Localizable.xcstrings).
nonisolated enum DockMenuStrings {
    static var newChat: String { String(localized: "dockMenu.newChat", defaultValue: "New Chat", bundle: .module) }
    static var newChatIn: String { String(localized: "dockMenu.newChatIn", defaultValue: "New Chat in", bundle: .module) }
    static var unread: String { String(localized: "dockMenu.unread", defaultValue: "Unread", bundle: .module) }
    static var recent: String { String(localized: "dockMenu.recent", defaultValue: "Recent", bundle: .module) }
    static var more: String { String(localized: "dockMenu.more", defaultValue: "More", bundle: .module) }

    static func continueChat(_ title: String) -> String {
        String(format: String(localized: "dockMenu.continue", defaultValue: "Continue “%@”", bundle: .module), title)
    }
}
