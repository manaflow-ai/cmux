import AppKit

@MainActor
final class TaskManagerWindowMenuInstaller: NSObject {
    static let shared = TaskManagerWindowMenuInstaller()

    private var didStart = false
    private var menuItem: NSMenuItem?

    private override init() {}

    func start() {
        guard !didStart else { return }
        didStart = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppMenuReady(_:)),
            name: NSApplication.didFinishLaunchingNotification,
            object: NSApp
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppMenuReady(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        DispatchQueue.main.async { [weak self] in
            self?.installIfNeeded()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleAppMenuReady(_ notification: Notification) {
        installIfNeeded()
    }

    @objc private func openTaskManager(_ sender: Any?) {
        TaskManagerWindowController.shared.show()
    }

    private func installIfNeeded() {
        guard let windowMenu = resolvedWindowMenu() else { return }

        let item: NSMenuItem
        if let menuItem {
            item = menuItem
        } else {
            item = NSMenuItem(
                title: String(localized: "menu.window.taskManager", defaultValue: "Task Manager..."),
                action: #selector(openTaskManager(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menuItem = item
        }

        if item.menu === windowMenu {
            return
        }
        item.menu?.removeItem(item)
        insert(item, into: windowMenu)
    }

    private func resolvedWindowMenu() -> NSMenu? {
        if let windowsMenu = NSApp.windowsMenu {
            return windowsMenu
        }
        return NSApp.mainMenu?.items.first { menuItem in
            menuItem.submenu?.items.contains(where: { item in
                item.action == #selector(NSApplication.arrangeInFront(_:))
            }) == true
        }?.submenu
    }

    private func insert(_ item: NSMenuItem, into windowMenu: NSMenu) {
        if let arrangeIndex = windowMenu.items.firstIndex(where: { menuItem in
            menuItem.action == #selector(NSApplication.arrangeInFront(_:))
        }) {
            if arrangeIndex > 0, !windowMenu.items[arrangeIndex - 1].isSeparatorItem {
                windowMenu.insertItem(.separator(), at: arrangeIndex)
            }
            let insertionIndex = windowMenu.items.firstIndex(where: { menuItem in
                menuItem.action == #selector(NSApplication.arrangeInFront(_:))
            }) ?? windowMenu.items.count
            windowMenu.insertItem(item, at: insertionIndex)
            return
        }

        if let lastItem = windowMenu.items.last, !lastItem.isSeparatorItem {
            windowMenu.addItem(.separator())
        }
        windowMenu.addItem(item)
    }
}
