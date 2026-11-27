import AppKit
import CmuxNextActions
import CmuxNextFiles
import UniformTypeIdentifiers
import CmuxNextFilesUI

/// The file explorer's Open With submenu, as Finder shows it: every app the
/// system reports for the file's type, the default first and marked, the
/// others by name (``OpenWithList``), then Other… (any app in Applications).
/// Each row is a registry row of the `fileExplorerRow` menu running Open With
/// (`fileExplorerOpenWith`) with the app's path (Other… without one: the person
/// picks it), so the menu, the palette and the CLI share one path.
final class FileExplorerOpenWithMenu: NSObject {
    private let registry: ActionRegistry

    init(registry: ActionRegistry) {
        self.registry = registry
    }

    /// Turns `menu`'s Open With row (the registry's `fileExplorerOpenWith`) into the apps
    /// submenu for `row`'s item, in the same place.
    func attach(to root: NSMenu, for row: FileExplorerRow, apps: any FileAppsProviding) {
        // Wherever the person placed it (Settings > Menus can move it into More).
        guard let (menu, index) = ActionRegistry.locate("fileExplorerOpenWith", in: root) else { return }
        let image = menu.items[index].image
        // The menu's arguments (the tree it was opened in) go to every app row's run.
        let arguments = ActionRegistry.menuRun(of: menu.items[index])?.arguments ?? [:]
        menu.removeItem(at: index)
        let item = item(for: row, apps: apps, arguments: arguments)
        item.image = image
        menu.insertItem(item, at: index)
    }

    /// The Open With row for `row`'s item; its submenu fills when LaunchServices answers
    /// (off the main thread, usually before the pointer reaches it).
    func item(for row: FileExplorerRow, apps: any FileAppsProviding, arguments: [String: ActionValue] = [:]) -> NSMenuItem {
        let item = NSMenuItem(title: FileExplorerStrings.openWithSubmenu, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: FileExplorerStrings.openWithSubmenu)
        let loading = NSMenuItem(title: FileExplorerStrings.loadingApps, action: nil, keyEquivalent: "")
        loading.isEnabled = false
        submenu.addItem(loading)
        item.submenu = submenu
        let name = row.name, isFolder = row.isFolder
        // task-owner: one LaunchServices lookup; ends when the submenu is filled.
        Task { [weak self, weak submenu] in
            let list = await apps.openWithList(forFileNamed: name, isDirectory: isFolder)
            guard let self, let submenu else { return }
            self.fill(submenu, with: list, arguments: arguments)
        }
        return item
    }

    /// Puts `list`'s rows into `submenu`: the default app, a separator, the others, a separator, Other….
    func fill(_ submenu: NSMenu, with list: OpenWithList, arguments: [String: ActionValue] = [:]) {
        submenu.removeAllItems()
        for (index, app) in list.apps.enumerated() {
            let title = app.isDefault ? FileExplorerStrings.defaultApp(app.name) : app.name
            guard let row = registry.makeContextMenuItem(for: "fileExplorerOpenWith", in: .fileExplorerRow,
                                                         arguments: arguments.merging(["app": .string(app.url.path)]) { $1 }, title: title) else { continue }
            if FileManager.default.fileExists(atPath: app.url.path) {
                let icon = NSWorkspace.shared.icon(forFile: app.url.path)
                icon.size = NSSize(width: 16, height: 16)
                row.image = icon
            }
            submenu.addItem(row)
            if index == 0, app.isDefault, list.apps.count > 1 { submenu.addItem(.separator()) }
        }
        if !list.apps.isEmpty { submenu.addItem(.separator()) }
        if let other = registry.makeContextMenuItem(for: "fileExplorerOpenWith", in: .fileExplorerRow, arguments: arguments,
                                                   title: FileExplorerStrings.openWithOther) {
            submenu.addItem(other)
        }
    }

    /// Other…: an open panel on Applications that picks one app for `item`.
    static func chooseApp(for item: URL, then open: @escaping @MainActor (String) -> Void) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = FileExplorerStrings.chooseApp(item.lastPathComponent)
        panel.prompt = FileExplorerStrings.openPrompt
        // task-owner: one open panel; ends when the person picks an app or cancels.
        Task { @MainActor in
            guard await panel.begin() == .OK, let app = panel.url else { return }
            open(app.path)
        }
    }
}
