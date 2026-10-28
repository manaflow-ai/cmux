public import AppKit
public import CmuxNextSettings
import UniformTypeIdentifiers

/// One row of a link's or a path's context menu (cx-ir3z4): plain data, so the debug socket
/// reads the same rows a right-click draws (``LinkMenu/items(_:)``).
public struct LinkMenuRow: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case openInCmuxBrowser, openInNewCmuxTab, openInDefaultBrowser, openIn, copyLink
        case open, openInTextEditor, openWith, openWithOther, revealInFinder, copyPath
        /// One app in an Open In or Open With submenu.
        case app

        /// The row's SF Symbol (the catalog's for the same action: Open Link in New Tab, Copy
        /// Link, Reveal in Finder, Copy Path); nil for an app row, which shows the app's icon.
        var symbol: String? {
            switch self {
            case .openInCmuxBrowser: "globe"
            case .openInNewCmuxTab: "plus.square.on.square"
            case .openInDefaultBrowser: "arrow.up.right.square"
            case .openIn, .openWith: "arrow.up.forward.app"
            case .copyLink: "link"
            case .open: "doc"
            case .openInTextEditor: "square.and.pencil"
            case .openWithOther: "ellipsis.circle"
            case .revealInFinder: "folder"
            case .copyPath: "doc.on.doc"
            case .app: nil
            }
        }
    }

    public var kind: Kind
    public var title: String
    /// The app of an ``Kind/app`` row.
    public var app: URL?
    public var children: [LinkMenuRow]

    public init(_ kind: Kind, _ title: String, app: URL? = nil, children: [LinkMenuRow] = []) {
        self.kind = kind
        self.title = title
        self.app = app
        self.children = children
    }

    /// The row as JSON (the debug socket's readback).
    public var json: JSONValue {
        var row: [String: JSONValue] = ["kind": .string(kind.rawValue), "title": .string(title)]
        if let app { row["app"] = .string(app.path) }
        if !children.isEmpty { row["children"] = .array(children.map(\.json)) }
        return .object(row)
    }
}

/// The link and path menus every surface shows (terminal, agent chat): the rows from their
/// inputs (``linkRows(for:browsers:)``, ``pathRows(for:isDirectory:apps:editor:)``, pure), the
/// app lists from LaunchServices when the menu opens, and the items that run them through
/// ``LinkRouter``.
public struct LinkMenu {
    public var router: LinkRouter
    /// Overrides Open in New cmux Browser Tab (a terminal's own tab's pane); nil: the router's.
    public var openInNewTab: ((URL) -> Void)?
    /// Overrides Copy Link and Copy Path (tests); nil: the router's.
    public var copy: ((String) -> Void)?
    /// Whether a row may still act, checked when it runs and when its panel answers (an agent
    /// chat's: still on this Mac); nil: always.
    public var allowed: (@MainActor () -> Bool)?
    /// The most apps a submenu lists.
    nonisolated static let appLimit = 24

    public init(router: LinkRouter = .shared, openInNewTab: ((URL) -> Void)? = nil) {
        self.router = router
        self.openInNewTab = openInNewTab
    }

    // MARK: Rows (pure)

    /// Open in cmux Browser, Open in New cmux Browser Tab, Open in Default Browser, Open In ▸
    /// (each browser, the default first) and Copy Link, for an http(s) link; no rows for another.
    public func linkRows(for url: URL, browsers: [URL]) -> [LinkMenuRow] {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return [] }
        var rows = [
            LinkMenuRow(.openInCmuxBrowser, Strings.openInCmuxBrowser),
            LinkMenuRow(.openInNewCmuxTab, Strings.openInNewCmuxTab),
            LinkMenuRow(.openInDefaultBrowser, Strings.openInDefaultBrowser),
        ]
        if !browsers.isEmpty {
            rows.append(LinkMenuRow(.openIn, Strings.openIn, children: browsers.map { LinkMenuRow(.app, Self.name(of: $0), app: $0) }))
        }
        rows.append(LinkMenuRow(.copyLink, Strings.copyLink))
        return rows
    }

    /// Open (its default app; left out for an app or an executable, which would run), Open in
    /// Text Editor (left out without an editor, and for a folder), Open With ▸ (each app, then
    /// Other…), Reveal in Finder and Copy Path.
    public func pathRows(for file: URL, isDirectory: Bool, runs: Bool = false, apps: [URL], editor: URL?) -> [LinkMenuRow] {
        var rows: [LinkMenuRow] = []
        if !runs { rows.append(LinkMenuRow(.open, Strings.open)) }
        if let editor, !isDirectory { rows.append(LinkMenuRow(.openInTextEditor, Strings.openInTextEditor, app: editor)) }
        let choices = apps.map { LinkMenuRow(.app, Self.name(of: $0), app: $0) } + [LinkMenuRow(.openWithOther, Strings.other)]
        rows.append(LinkMenuRow(.openWith, Strings.openWith, children: choices))
        rows.append(LinkMenuRow(.revealInFinder, Strings.revealInFinder))
        rows.append(LinkMenuRow(.copyPath, Strings.copyPath))
        return rows
    }

    // MARK: App lists (LaunchServices, when a menu opens)

    /// The browsers that open `url`, the default first, without this app.
    /// The shared workspace's answer is kept per scheme (``LinkMenuAppCache``).
    public func browsers(for url: URL, workspace: NSWorkspace = .shared) -> [URL] {
        let ask: @Sendable () -> [URL] = { [url] in
            let workspace = NSWorkspace.shared
            return Self.ordered(workspace.urlsForApplications(toOpen: url), first: workspace.urlForApplication(toOpen: url),
                                excluding: Bundle.main.bundleURL)
        }
        guard workspace === NSWorkspace.shared, let scheme = url.scheme?.lowercased() else {
            return Self.ordered(workspace.urlsForApplications(toOpen: url), first: workspace.urlForApplication(toOpen: url),
                                excluding: Bundle.main.bundleURL)
        }
        // http and https open in the same browsers.
        return LinkMenuAppCache.shared.apps(for: "link:" + (scheme == "https" ? "http" : scheme), compute: ask)
    }

    /// The apps that open `file`, its default first. The shared workspace's answer is kept per
    /// content type (``LinkMenuAppCache``); a file without one is asked every time.
    public func apps(for file: URL, workspace: NSWorkspace = .shared) -> [URL] {
        guard workspace === NSWorkspace.shared,
              let type = try? file.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return Self.ordered(workspace.urlsForApplications(toOpen: file), first: workspace.urlForApplication(toOpen: file), excluding: nil)
        }
        let kept = LinkMenuAppCache.shared.apps(for: "type:" + type.identifier) { [type] in
            NSWorkspace.shared.urlsForApplications(toOpen: type)
        }
        // The default stays per file: Get Info's "Open with" can name another app for one document.
        return Self.ordered(kept, first: workspace.urlForApplication(toOpen: file), excluding: nil)
    }

    /// `files.textEditor` when it names an installed app, else the system's app for source code
    /// (then plain text); nil when there is none.
    public func editor(workspace: NSWorkspace = .shared) -> URL? {
        let setting = router.textEditor()
        if !setting.isEmpty, let app = Self.application(named: setting, workspace: workspace) { return app }
        return workspace.urlForApplication(toOpen: .sourceCode) ?? workspace.urlForApplication(toOpen: .plainText)
    }

    /// Whether opening `file` in its default app would run something: an app or another
    /// package, or an executable file.
    public static func runs(_ file: URL, isDirectory: Bool) -> Bool {
        if (try? file.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return true }
        return !isDirectory && FileManager.default.isExecutableFile(atPath: file.path)
    }

    /// The link rows with this Mac's browsers.
    public func linkRows(for url: URL) -> [LinkMenuRow] {
        // Rows exist only for http(s): ask LaunchServices for nothing else.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return [] }
        return linkRows(for: url, browsers: browsers(for: url))
    }

    /// The path rows with this Mac's apps and the text editor setting.
    public func pathRows(for file: URL, isDirectory: Bool) -> [LinkMenuRow] {
        pathRows(for: file, isDirectory: isDirectory, runs: Self.runs(file, isDirectory: isDirectory),
                 apps: apps(for: file), editor: editor())
    }

    /// Resolves a bundle identifier, an app path, or an app name ("Visual Studio Code") in the
    /// standard application folders.
    public static func application(named name: String, workspace: NSWorkspace = .shared) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let url = workspace.urlForApplication(withBundleIdentifier: trimmed) { return url }
        let paths = FileManager.default
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            let path = (trimmed as NSString).expandingTildeInPath
            return paths.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let bundleName = trimmed.hasSuffix(".app") ? trimmed : trimmed + ".app"
        let folders = paths.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask, .systemDomainMask])
            + [URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/Applications/Utilities")]
        return folders.map { $0.appending(path: bundleName) }.first { paths.fileExists(atPath: $0.path) }
    }

    nonisolated static func ordered(_ apps: [URL], first: URL?, excluding own: URL?) -> [URL] {
        var seen = Set<String>()
        let own = own?.standardizedFileURL.path
        return ([first].compactMap { $0 } + apps).filter { app in
            let path = app.standardizedFileURL.path
            return path != own && seen.insert(path).inserted
        }.prefix(appLimit).map { $0 }
    }

    static func name(of app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    // MARK: Items

    /// The menu items of a link's rows.
    public func linkItems(for url: URL) -> [NSMenuItem] { items(linkRows(for: url), link: url) }

    /// The menu items of a path's rows.
    public func pathItems(for file: URL, isDirectory: Bool) -> [NSMenuItem] {
        items(pathRows(for: file, isDirectory: isDirectory), file: file)
    }

    /// Draws `rows` for a link (`link`) or a path (`file`).
    public func items(_ rows: [LinkMenuRow], link: URL? = nil, file: URL? = nil) -> [NSMenuItem] {
        rows.map { row in
            let item = PageMenuAction.item(row.title) { perform(row, link: link, file: file) }
            if let app = row.app, row.kind == .app {
                item.image = LinkMenuAppCache.icon(for: app)
            } else if let symbol = row.kind.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                // Every cmux menu row shows its action's symbol, as the action registry's menus do.
                image.isTemplate = true
                item.image = image
            }
            if !row.children.isEmpty {
                let submenu = NSMenu(title: row.title)
                items(row.children, link: link, file: file).forEach(submenu.addItem)
                item.submenu = submenu
                item.action = nil
            }
            return item
        }
    }

    func perform(_ row: LinkMenuRow, link: URL?, file: URL?) {
        guard allowed?() ?? true else { return }
        let copy = copy ?? router.copy
        if let link {
            switch row.kind {
            case .openInCmuxBrowser: router.open(link, in: .cmuxBrowser)
            case .openInNewCmuxTab:
                if let openInNewTab { openInNewTab(link) } else { router.open(link, in: .cmuxBrowser, background: true) }
            case .openInDefaultBrowser: router.open(link, in: .system)
            case .copyLink: copy(link.absoluteString)
            case .app: if let app = row.app { router.open(link, withApplicationAt: app) }
            default: break
            }
        }
        guard let file else { return }
        switch row.kind {
        case .open: router.openFile(file)
        case .openInTextEditor, .app: if let app = row.app { router.open(file, withApplicationAt: app) }
        case .openWithOther: chooseApp(for: file)
        case .revealInFinder: router.showInFinder(file, reveal: true)
        case .copyPath: copy(file.path)
        default: break
        }
    }

    /// Other…: a panel in Applications; the chosen app opens the file.
    func chooseApp(for file: URL) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = Strings.open
        let menu = self
        panel.begin { response in
            guard response == .OK, let app = panel.url else { return }
            menu.openChosen(app, for: file)
        }
    }

    /// Other…'s answer: `file` in `app`, unless the menu may no longer act.
    func openChosen(_ app: URL, for file: URL) {
        guard allowed?() ?? true else { return }
        router.open(file, withApplicationAt: app)
    }

    enum Strings {
        static var openInCmuxBrowser: String {
            String(localized: "links.menu.openInCmuxBrowser", defaultValue: "Open in cmux Browser", bundle: .module)
        }

        static var openInNewCmuxTab: String {
            String(localized: "links.menu.openInNewCmuxTab", defaultValue: "Open in New cmux Browser Tab", bundle: .module)
        }

        static var openInDefaultBrowser: String {
            String(localized: "links.menu.openInDefaultBrowser", defaultValue: "Open in Default Browser", bundle: .module)
        }

        static var openIn: String {
            String(localized: "links.menu.openIn", defaultValue: "Open In", bundle: .module)
        }

        static var copyLink: String {
            String(localized: "links.menu.copyLink", defaultValue: "Copy Link", bundle: .module)
        }

        static var open: String {
            String(localized: "links.menu.open", defaultValue: "Open", bundle: .module)
        }

        static var openInTextEditor: String {
            String(localized: "links.menu.openInTextEditor", defaultValue: "Open in Text Editor", bundle: .module)
        }

        static var openWith: String {
            String(localized: "links.menu.openWith", defaultValue: "Open With", bundle: .module)
        }

        static var other: String {
            String(localized: "links.menu.other", defaultValue: "Other…", bundle: .module)
        }

        static var revealInFinder: String {
            String(localized: "links.menu.revealInFinder", defaultValue: "Reveal in Finder", bundle: .module)
        }

        static var copyPath: String {
            String(localized: "links.menu.copyPath", defaultValue: "Copy Path", bundle: .module)
        }
    }
}
