import AppKit
import CmuxNextActionsAppKit
import CmuxNextFiles
import UniformTypeIdentifiers
import CmuxNextFilesUI
import CmuxNextWakeups

/// The file explorer's Open With submenu, as Finder shows it: every app the
/// system reports for the file's type, the default first and marked, the
/// others by name (``OpenWithList``), then Other… (any app in Applications).
/// Each row is a registry row of the `fileExplorerRow` menu running Open With
/// (`fileExplorerOpenWith`) with the app's path (Other… without one: the person
/// picks it), so the menu, the palette and the CLI share one path.
final class FileExplorerOpenWithMenu: NSObject {
    private let registry: ActionRegistry
    private let mainWork: MainWorkScheduler
    private let appIcon: @MainActor (URL, NSMenuItem) -> Void

    /// - Parameters:
    ///   - registry: The registry whose `fileExplorerOpenWith` each row runs.
    ///   - mainWork: The app's main-thread scheduler: a submenu Launch Services answers late fills as one task on it.
    ///   - appIcon: Sets an app row's image to the app's icon, now or when it lands (`WorkspaceFileApps.showIcon`);
    ///     no icons by default.
    init(registry: ActionRegistry, mainWork: MainWorkScheduler, appIcon: @escaping @MainActor (URL, NSMenuItem) -> Void = { _, _ in }) {
        self.registry = registry
        self.mainWork = mainWork
        self.appIcon = appIcon
    }

    /// Turns `menu`'s Open With row (the registry's `fileExplorerOpenWith`) into the apps
    /// submenu for `row`'s item, in the same place.
    func attach(to menu: NSMenu, for row: FileExplorerRow, apps: any FileAppsProviding) {
        guard let index = menu.items.firstIndex(where: { ActionRegistry.menuRun(of: $0)?.id == "fileExplorerOpenWith" }) else { return }
        let image = menu.items[index].image
        // The menu's arguments (the tree it was opened in) go to every app row's run.
        let arguments = ActionRegistry.menuRun(of: menu.items[index])?.arguments ?? [:]
        menu.removeItem(at: index)
        let item = item(for: row, apps: apps, arguments: arguments)
        item.image = image
        menu.insertItem(item, at: index)
    }

    /// The Open With row for `row`'s item; its submenu fills from the kept list at once, else when Launch
    /// Services answers on the system lane (usually before the pointer reaches it).
    func item(for row: FileExplorerRow, apps: any FileAppsProviding, arguments: [String: ActionValue] = [:]) -> NSMenuItem {
        let item = NSMenuItem(title: FileExplorerStrings.openWithSubmenu, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: FileExplorerStrings.openWithSubmenu)
        let loading = NSMenuItem(title: FileExplorerStrings.loadingApps, action: nil, keyEquivalent: "")
        loading.isEnabled = false
        submenu.addItem(loading)
        item.submenu = submenu
        let name = row.name, isFolder = row.isFolder
        if let kept = apps.keptOpenWithList(forFileNamed: name, isDirectory: isFolder) {
            fill(submenu, with: kept, arguments: arguments)
            return item
        }
        // task-owner: one LaunchServices lookup off main; ends when the submenu is filled. The fill is the rest of the
        // person's right-click (userBlocking), posted in the common modes, so it runs while the menu tracks.
        // The off-main task holds only Sendable values; the menu and its submenu stay in a main-actor closure.
        let mainWork = mainWork
        let fillLate: @MainActor @Sendable (OpenWithList) -> Void = { [weak self, weak submenu] list in
            guard let self, let submenu else { return }
            fill(submenu, with: list, arguments: arguments)
        }
        Task { @concurrent in
            let list = await apps.openWithList(forFileNamed: name, isDirectory: isFolder)
            mainWork.postFromAnyThread(.userBlocking, owner: "FileExplorerOpenWith.fill") { fillLate(list) }
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
            appIcon(app.url, row)
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
        // The panel calls back on the main thread in the turn the person picks: no task to hop back.
        let picked: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let app = panel.url else { return }
            open(app.path)
        }
        panel.begin(completionHandler: picked)
    }
}
