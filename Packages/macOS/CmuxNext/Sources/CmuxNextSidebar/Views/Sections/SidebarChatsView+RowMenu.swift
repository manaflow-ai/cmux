import AppKit

// A chat row's right-click menu (Lawrence 2026-10-09): a click opens the chat as the agent pane in
// a new workspace; Open in Terminal is only here.
extension SidebarChatsView {
    public static var openChatTitle: String {
        String(localized: "sidebar.chats.menu.open", defaultValue: "Open Chat", bundle: .module)
    }
    public static var openInTerminalTitle: String {
        String(localized: "sidebar.chats.menu.openInTerminal", defaultValue: "Open in Terminal", bundle: .module)
    }

    /// Open Chat, then Open in Terminal, for chat `id`.
    func rowMenu(_ id: String) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [(Self.openChatTitle, #selector(openFromMenu(_:))), (Self.openInTerminalTitle, #selector(openInTerminalFromMenu(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.representedObject = id
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    func showRowMenu(_ id: String, event: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(rowMenu(id), with: event, for: view)
    }

    @objc func openFromMenu(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { onOpen?(id) }
    }

    @objc func openInTerminalFromMenu(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { onOpenInTerminal?(id) }
    }
}
