import AppKit
import CmuxNextFiles
import UniformTypeIdentifiers

/// The file explorer's Open With submenu, as Finder shows it: every app the
/// system reports for the file's type, the default first and marked, the
/// others by name (``OpenWithList``), then Other… (any app in Applications).
/// A row runs `open` with the app's path, which the explorer sends as Open With
/// (`fileExplorerOpenWith`), so the menu, the palette and the CLI share one path.
final class FileExplorerOpenWithMenu: NSObject {
    private let open: @MainActor (String) -> Void
    private let chooseOther: @MainActor () -> Void

    /// - Parameters:
    ///   - open: Opens the selection with the app at this path.
    ///   - chooseOther: Other…: lets the person pick any app.
    init(open: @escaping @MainActor (String) -> Void, chooseOther: @escaping @MainActor () -> Void) {
        self.open = open
        self.chooseOther = chooseOther
    }

    /// The Open With row for `row`'s item; its submenu fills when LaunchServices answers
    /// (off the main thread, usually before the pointer reaches it).
    func item(for row: FileExplorerRow, apps: any FileAppsProviding) -> NSMenuItem {
        let item = NSMenuItem(title: FileExplorerStrings.openWithSubmenu, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: FileExplorerStrings.openWithSubmenu)
        submenu.autoenablesItems = false
        let loading = NSMenuItem(title: FileExplorerStrings.loadingApps, action: nil, keyEquivalent: "")
        loading.isEnabled = false
        submenu.addItem(loading)
        item.submenu = submenu
        let name = row.name, isFolder = row.isFolder
        // task-owner: one LaunchServices lookup; ends when the submenu is filled.
        Task { [weak self, weak submenu] in
            let list = await apps.openWithList(forFileNamed: name, isDirectory: isFolder)
            guard let self, let submenu else { return }
            self.fill(submenu, with: list)
        }
        return item
    }

    /// Puts `list`'s rows into `submenu`: the default app, a separator, the others, a separator, Other….
    func fill(_ submenu: NSMenu, with list: OpenWithList) {
        submenu.removeAllItems()
        for (index, app) in list.apps.enumerated() {
            let title = app.isDefault ? FileExplorerStrings.defaultApp(app.name) : app.name
            let row = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = app.url.path
            if FileManager.default.fileExists(atPath: app.url.path) {
                let icon = NSWorkspace.shared.icon(forFile: app.url.path)
                icon.size = NSSize(width: 16, height: 16)
                row.image = icon
            }
            submenu.addItem(row)
            if index == 0, app.isDefault, list.apps.count > 1 { submenu.addItem(.separator()) }
        }
        if !list.apps.isEmpty { submenu.addItem(.separator()) }
        let other = NSMenuItem(title: FileExplorerStrings.openWithOther, action: #selector(pickedOther(_:)), keyEquivalent: "")
        other.target = self
        submenu.addItem(other)
    }

    @objc private func picked(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        open(path)
    }

    @objc private func pickedOther(_ sender: NSMenuItem) {
        chooseOther()
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
