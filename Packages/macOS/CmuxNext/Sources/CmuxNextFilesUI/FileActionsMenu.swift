public import AppKit
import CmuxNextDesign
public import CmuxNextFiles
import Quartz
import UniformTypeIdentifiers

/// The one right-click menu for a file, shared by Home attachments, Home file links and the
/// Files pane (plans/cmux-next/files-finder-parity-DESIGN.md, 1):
/// Open in Right Pane · Open as Text (a rendered page) · Open With ▸ · Quick Look · Reveal in Finder · Reveal in cmux Files ·
/// Copy as Pathname · Share….
///
/// The rows are built from the file's name, so the menu shows at once; `resolve` gives the file
/// on disk when a row runs (a Home attachment is fetched only then). Open With lists every app
/// the system reports for the type, the default first, then Other….
///
/// ```swift
/// let menu = FileActionsMenu(actions: .init(openInCmux: { opener.openFile($0) },
///                                           revealInFiles: { files.reveal($0) }))
/// menu.items(forFileNamed: "index.html") { url }.forEach(contextMenu.addItem)
/// ```
@MainActor
public final class FileActionsMenu {
    /// What the host does for the cmux-side rows.
    public struct Actions {
        /// Open in Right Pane: cmux shows the file beside the source pane.
        public var openInCmux: @MainActor (URL) -> Void
        /// Reveal in cmux Files: a Files pane tab on the folder, the file selected.
        public var revealInFiles: @MainActor (URL) -> Void
        /// Open as Text: cmux shows a rendered page's source (HTML, SVG, Markdown) in the code
        /// editor; nil leaves the row out.
        public var openAsText: (@MainActor (URL) -> Void)?

        /// The host's cmux actions.
        ///
        /// - Parameters:
        ///   - openInCmux: opens a file in cmux (``LinkOpener`` in the app).
        ///   - revealInFiles: shows the file selected in a Files pane tab.
        ///   - openAsText: opens a file's text in the code editor; nil (the default) offers no Open as Text.
        public init(openInCmux: @escaping @MainActor (URL) -> Void, revealInFiles: @escaping @MainActor (URL) -> Void,
                    openAsText: (@MainActor (URL) -> Void)? = nil) {
            self.openInCmux = openInCmux
            self.revealInFiles = revealInFiles
            self.openAsText = openAsText
        }
    }

    /// Open as Text's title, as the menus show it.
    public static var openAsTextTitle: String { FileActionStrings.openAsText }

    private let apps: any FileAppsProviding
    private let actions: Actions
    private let quickLook = QuickLookSource()

    /// A menu builder.
    ///
    /// - Parameters:
    ///   - apps: the Open With seam; the system's apps by default, a fake in tests.
    ///   - actions: the host's cmux actions.
    public init(apps: any FileAppsProviding = WorkspaceFileApps(), actions: Actions) {
        self.apps = apps
        self.actions = actions
    }

    /// The rows for an item named `name`.
    ///
    /// - Parameters:
    ///   - name: the file's name (its extension picks the Open With apps).
    ///   - isDirectory: the item is a folder or package.
    ///   - includeOpen: false leaves out Open in Right Pane (the Files pane has its own Open).
    ///   - resolve: the file on disk, fetched when a row runs; nil does nothing.
    /// - Returns: the rows, with separators, to append to a context menu.
    public func items(forFileNamed name: String, isDirectory: Bool = false, includeOpen: Bool = true,
                      resolve: @escaping @MainActor @Sendable () async -> URL?) -> [NSMenuItem] {
        var rows: [NSMenuItem] = []
        let open = actions.openInCmux, reveal = actions.revealInFiles
        if includeOpen {
            rows.append(menuRow(FileActionStrings.openInRightPane, "rectangle.righthalf.inset.filled") { Self.run(resolve, open) })
            if let text = openAsTextItem(forFileNamed: name, isDirectory: isDirectory, resolve: resolve) { rows.append(text) }
        }
        rows.append(openWithItem(forFileNamed: name, isDirectory: isDirectory, resolve: resolve))
        rows.append(.separator())
        rows.append(menuRow(FilesStrings.quickLook, "eye") { [weak self] in Self.run(resolve) { self?.showQuickLook($0) } })
        rows.append(menuRow(FilesStrings.showInFinder, "macwindow") { Self.run(resolve) { NSWorkspace.shared.revealInBackground([$0]) } })
        rows.append(menuRow(FileActionStrings.revealInFiles, "folder") { Self.run(resolve, reveal) })
        rows.append(menuRow(FilesStrings.copyPath, "link") { Self.run(resolve) { FilePasteboard.writePaths([$0], to: .general) } })
        rows.append(shareItem(resolve: resolve))
        return rows
    }

    /// Open as Text: the file's source in the code editor, for a page cmux renders (HTML, SVG,
    /// Markdown: ``FileOpenKind/opensAsText``). Nil for another file, or when the host gave no
    /// ``Actions/openAsText``.
    ///
    /// - Parameters:
    ///   - name: the file's name (its extension says whether it renders).
    ///   - isDirectory: the item is a folder or package (never offered).
    ///   - resolve: the file on disk, fetched when the row runs.
    /// - Returns: the row, or nil.
    public func openAsTextItem(forFileNamed name: String, isDirectory: Bool = false,
                               resolve: @escaping @MainActor @Sendable () async -> URL?) -> NSMenuItem? {
        guard let open = actions.openAsText, !isDirectory,
              FileOpenKind(fileName: name, isDirectory: false, isPackage: false).opensAsText else { return nil }
        return menuRow(FileActionStrings.openAsText, "chevron.left.forwardslash.chevron.right") { Self.run(resolve, open) }
    }

    /// Share…: the system share picker for the file, at the pointer.
    public func shareItem(resolve: @escaping @MainActor @Sendable () async -> URL?) -> NSMenuItem {
        menuRow(FileActionStrings.share, "square.and.arrow.up") { Self.run(resolve) { Self.share($0) } }
    }

    /// Open With ▸: every app the system reports for the type, the default first, then Other….
    /// Filled when the app list arrives (usually before the pointer reaches it).
    ///
    /// - Parameters:
    ///   - name: the file's name (its extension picks the apps).
    ///   - isDirectory: the item is a folder or package.
    ///   - resolve: the file on disk, fetched when a row runs.
    public func openWithItem(forFileNamed name: String, isDirectory: Bool = false,
                             resolve: @escaping @MainActor @Sendable () async -> URL?) -> NSMenuItem {
        let row = NSMenuItem(title: FileActionStrings.openWith, action: nil, keyEquivalent: "")
        row.image = NSImage.menuSymbol("arrow.up.forward.app")
        let submenu = NSMenu(title: FileActionStrings.openWith)
        let loading = NSMenuItem(title: FilesStrings.loading, action: nil, keyEquivalent: "")
        loading.isEnabled = false
        submenu.addItem(loading)
        submenu.autoenablesItems = false
        row.submenu = submenu
        let apps = self.apps
        // task-owner: one LaunchServices lookup; ends when the submenu is filled
        Task { @MainActor in
            let list = await apps.openWithList(forFileNamed: name, isDirectory: isDirectory)
            submenu.removeAllItems()
            for (index, app) in list.apps.enumerated() {
                let title = app.isDefault ? FileActionStrings.defaultApp(app.name) : app.name
                let item = menuRow(title, nil) { Self.run(resolve) { file in Task { _ = await apps.open([file], withApplicationAt: app.url) } } }
                let icon = NSWorkspace.shared.icon(forFile: app.url.path)
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                submenu.addItem(item)
                if index == 0, app.isDefault, list.apps.count > 1 { submenu.addItem(.separator()) }
            }
            if !list.apps.isEmpty { submenu.addItem(.separator()) }
            submenu.addItem(menuRow(FileActionStrings.other, nil) { Self.run(resolve) { Self.chooseApp(for: $0, apps: apps) } })
        }
        return row
    }

    private static func run(_ resolve: @escaping @MainActor @Sendable () async -> URL?, _ action: @escaping @MainActor (URL) -> Void) {
        // task-owner: one resolve (a Home attachment may download); ends when the action runs
        Task { @MainActor in if let file = await resolve() { action(file) } }
    }

    /// Other…: pick any app in Applications.
    private static func chooseApp(for file: URL, apps: any FileAppsProviding) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = FileActionStrings.chooseApp(file.lastPathComponent)
        panel.prompt = FilesStrings.open
        panel.begin { response in
            guard response == .OK, let app = panel.url else { return }
            // task-owner: one open with the chosen app
            Task { _ = await apps.open([file], withApplicationAt: app) }
        }
    }

    private func showQuickLook(_ file: URL) {
        guard let panel = QLPreviewPanel.shared() else { return }
        quickLook.urls = [file]
        panel.dataSource = quickLook
        panel.delegate = quickLook
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Share…: the system share picker at the pointer, in the key window.
    private static func share(_ file: URL) {
        guard let view = NSApp.keyWindow?.contentView, let window = view.window else { return }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        NSSharingServicePicker(items: [file]).show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)),
                                                   of: view, preferredEdge: .minY)
    }
}

/// A menu row that runs a closure: the item's target, kept alive by the item (`representedObject`).
@MainActor
private final class RowTarget: NSObject {
    private let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
    }

    @objc func fire(_ sender: Any?) { run() }
}

/// A menu row titled `title` (with an SF Symbol) that runs `run`.
@MainActor
private func menuRow(_ title: String, _ symbol: String?, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
    let target = RowTarget(run)
    let item = NSMenuItem(title: title, action: #selector(RowTarget.fire(_:)), keyEquivalent: "")
    item.target = target
    item.representedObject = target
    if let symbol { item.image = NSImage.menuSymbol(symbol) }
    return item
}
