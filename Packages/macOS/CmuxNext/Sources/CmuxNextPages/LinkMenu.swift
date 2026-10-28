public import AppKit
import CmuxNextCompat
public import CmuxNextSettings
public import CmuxNextWakeups
import UniformTypeIdentifiers

/// One row of a link's or a path's context menu (cx-ir3z4): plain data, so the debug socket
/// reads the same rows a right-click draws (``LinkMenu/items(_:)``).
public struct LinkMenuRow: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case openInCmuxBrowser, openInNewCmuxTab, openInDefaultBrowser, openIn, copyLink
        case open, openInTextEditor, openWith, openWithOther, revealInFinder, copyPath
        /// One app in an Open In or Open With submenu.
        case app
        /// The disabled Loading row of a submenu whose apps Launch Services has not given yet.
        case loading

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
            case .app, .loading: nil
            }
        }
    }

    /// The Launch Services answers a row was drawn without; its menu item fills in when they land
    /// (``LinkMenu/items(_:link:file:)``).
    public enum Waiting: Sendable, Equatable {
        /// The browsers of a link's scheme (Open In).
        case browsers(URL)
        /// A file's default app and its type's apps (Open With).
        case apps(URL, isDirectory: Bool)
        /// The text editor (Open in Text Editor): the row leaves the menu when there is none.
        case editor
    }

    public var kind: Kind
    public var title: String
    /// The app of an ``Kind/app`` row.
    public var app: URL?
    public var children: [LinkMenuRow]
    /// What the row still waits for; nil when it was drawn from kept answers only.
    public var waiting: Waiting?

    public init(_ kind: Kind, _ title: String, app: URL? = nil, children: [LinkMenuRow] = [], waiting: Waiting? = nil) {
        self.kind = kind
        self.title = title
        self.app = app
        self.children = children
        self.waiting = waiting
    }

    /// The row as JSON (the debug socket's readback).
    public var json: JSONValue {
        var row: [String: JSONValue] = ["kind": .string(kind.rawValue), "title": .string(title)]
        if let app { row["app"] = .string(app.path) }
        if !children.isEmpty { row["children"] = .array(children.map(\.json)) }
        if waiting != nil { row["waiting"] = .bool(true) }
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
    /// The app's Launch Services answers (``WorkspaceQueries``): the app lists and icons come from what it keeps,
    /// and a missing answer is asked on the system lane, never on the main thread. Nil lists no apps.
    public var queries: WorkspaceQueries?
    /// What the items a waiting submenu gets when its answers land go through, as the caller's own items went (the
    /// agent pane makes an SVG's rows write its rebuilt copy first); nil adds them as drawn.
    public var filledItems: (([NSMenuItem]) -> [NSMenuItem])?
    /// The most apps a submenu lists.
    nonisolated static let appLimit = 24

    public init(router: LinkRouter = .shared, queries: WorkspaceQueries?, openInNewTab: ((URL) -> Void)? = nil) {
        self.router = router
        self.queries = queries
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
        rows.append(Self.openWithRow(apps: apps))
        rows.append(LinkMenuRow(.revealInFinder, Strings.revealInFinder))
        rows.append(LinkMenuRow(.copyPath, Strings.copyPath))
        return rows
    }

    /// Open With ▸: each app, then Other….
    static func openWithRow(apps: [URL]) -> LinkMenuRow {
        let choices = apps.map { LinkMenuRow(.app, Self.name(of: $0), app: $0) } + [LinkMenuRow(.openWithOther, Strings.other)]
        return LinkMenuRow(.openWith, Strings.openWith, children: choices)
    }

    // MARK: App lists (Launch Services answers, kept by WorkspaceQueries)

    /// The browsers that open `url`'s scheme, the default first, without this app (http and https share one list).
    /// The kept list; on a miss, none, and the list is asked on the system lane for the next menu.
    public func browsers(for url: URL) -> [URL] {
        Self.browsersQuery(for: url).flatMap { kept($0) } ?? []
    }

    /// The apps that open `file`, its default first: the list kept per content type, the default per file (Get
    /// Info's "Open with" can name another app for one document). On a miss, the part that is kept.
    public func apps(for file: URL, isDirectory: Bool) -> [URL] {
        let type = Self.contentType(of: file, isDirectory: isDirectory)
        let first = kept(WorkspaceQuery<URL?>.defaultApplication(toOpen: file)) ?? nil
        return Self.ordered(kept(WorkspaceQuery<[URL]>.applications(toOpen: type)) ?? [], first: first, excluding: nil)
    }

    /// `files.textEditor` when it names an installed app, else the system's app for source code (then plain
    /// text); nil when there is none or the answer is not kept yet.
    public func editor() -> URL? {
        kept(Self.textEditor(setting: router.textEditor())) ?? nil
    }

    /// The app `setting` names (``application(named:)``) when it is installed, else the system's app for source
    /// code, then for plain text; nil with none. Asked on the system lane, kept per setting.
    public nonisolated static func textEditor(setting: String) -> WorkspaceQuery<URL?> {
        let named = setting.trimmingCharacters(in: .whitespaces)
        return WorkspaceQuery(id: "links.textEditor." + named, refreshes: true) { system in
            if !named.isEmpty, let app = Self.resolveApplication(named: named, system) { return app }
            return system.defaultApplication(toOpen: .sourceCode) ?? system.defaultApplication(toOpen: .plainText)
        }
    }

    /// The browsers for `scheme` links, the default first, without `own` (this app), at most ``appLimit``.
    public nonisolated static func browsers(scheme: String, own: URL) -> WorkspaceQuery<[URL]> {
        WorkspaceQuery(id: "links.browsers." + scheme, refreshes: true) { system in
            guard let probe = URL(string: scheme + "://example.com/") else { return [] }
            return Self.ordered(system.applications(toOpen: probe), first: system.defaultApplication(toOpen: probe), excluding: own)
        }
    }

    /// The type Launch Services matches apps against for `file`, from its name (no disk read).
    nonisolated static func contentType(of file: URL, isDirectory: Bool) -> UTType {
        let ext = file.pathExtension
        if ext.isEmpty { return isDirectory ? .folder : .plainText }
        return UTType(filenameExtension: ext, conformingTo: isDirectory ? .package : .data) ?? .data
    }

    /// Whether opening `file` in its default app would run something: an app or another
    /// package, or an executable file.
    public static func runs(_ file: URL, isDirectory: Bool) -> Bool {
        if (try? file.resourceValues(forKeys: [.isPackageKey]).isPackage) == true { return true }
        return !isDirectory && FileManager.default.isExecutableFile(atPath: file.path)
    }

    /// The link rows with this Mac's browsers. When the browsers are not kept yet, Open In ▸ shows the Loading row and
    /// waits for them (its item fills in, or leaves the menu when there are none).
    public func linkRows(for url: URL) -> [LinkMenuRow] {
        // Rows exist only for http(s): ask LaunchServices for nothing else.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return [] }
        guard queries != nil, let query = Self.browsersQuery(for: url), kept(query) == nil else {
            return linkRows(for: url, browsers: browsers(for: url))
        }
        var rows = linkRows(for: url, browsers: [])
        let waiting = LinkMenuRow(.openIn, Strings.openIn, children: [Self.loadingRow], waiting: .browsers(url))
        rows.insert(waiting, at: rows.firstIndex { $0.kind == .copyLink } ?? rows.endIndex)
        return rows
    }

    /// The path rows with this Mac's apps and the text editor setting. Rows whose answers are not kept yet wait for
    /// them: Open With ▸ fills in, and Open in Text Editor shows and leaves the menu when there is no editor.
    public func pathRows(for file: URL, isDirectory: Bool) -> [LinkMenuRow] {
        let editor = kept(Self.textEditor(setting: router.textEditor()))
        var rows = pathRows(for: file, isDirectory: isDirectory, runs: Self.runs(file, isDirectory: isDirectory),
                            apps: [], editor: editor ?? nil)
        guard let openWith = rows.firstIndex(where: { $0.kind == .openWith }) else { return rows }
        rows[openWith] = keptOpenWithRow(for: file, isDirectory: isDirectory)
        if queries != nil, editor == nil, !isDirectory {
            rows.insert(LinkMenuRow(.openInTextEditor, Strings.openInTextEditor, waiting: .editor), at: openWith)
        }
        return rows
    }

    /// The app `name` names: a bundle identifier, an app path, or an app name ("Visual Studio Code") in the
    /// standard application folders; asked on the system lane (``WorkspaceQueries``), kept per name.
    public nonisolated static func application(named name: String) -> WorkspaceQuery<URL?> {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return WorkspaceQuery(id: "links.application." + trimmed, refreshes: true) { system in
            Self.resolveApplication(named: trimmed, system)
        }
    }

    /// Resolves `name` (trimmed) to an app, reading Launch Services and the disk: off the main thread only.
    nonisolated static func resolveApplication(named name: String, _ system: any WorkspaceQuerying) -> URL? {
        guard !name.isEmpty else { return nil }
        if let url = system.application(withBundleIdentifier: name) { return url }
        let paths = FileManager.checked
        if name.hasPrefix("/") || name.hasPrefix("~/") {
            let path = (name as NSString).expandingTildeInPath
            return paths.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let bundleName = name.hasSuffix(".app") ? name : name + ".app"
        let folders = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask, .systemDomainMask])
            + [URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/Applications/Utilities")]
        return folders.map { $0.appending(path: bundleName) }.first { FileManager.checked.fileExists(atPath: $0.path) }
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
                queries?.image(WorkspaceQuery<NSImage>.fileIcon(atPath: app.path, side: 16), into: item)
            } else if let symbol = row.kind.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                // Every cmux menu row shows its action's symbol, as the action registry's menus do.
                image.isTemplate = true
                item.image = image
            }
            if row.kind == .loading {
                item.action = nil
                item.isEnabled = false
            }
            if !row.children.isEmpty {
                let submenu = NSMenu(title: row.title)
                items(row.children, link: link, file: file).forEach(submenu.addItem)
                item.submenu = submenu
                item.action = nil
            }
            if let waiting = row.waiting { fill(item, waiting: waiting, link: link, file: file) }
            return item
        }
    }

    func perform(_ row: LinkMenuRow, link: URL?, file: URL?) {
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
        case .app: if let app = row.app { router.open(file, withApplicationAt: app) }
        case .openInTextEditor: openInEditor(file, app: row.app)
        case .openWithOther: chooseApp(for: file)
        case .revealInFinder: router.showInFinder(file, reveal: true)
        case .copyPath: copy(file.path)
        default: break
        }
    }

    /// Opens `file` in `app`; a row drawn before the editor was known (nil `app`) opens it in the editor once the
    /// system lane names it.
    private func openInEditor(_ file: URL, app: URL?) {
        if let app { return router.open(file, withApplicationAt: app) }
        let router = router
        queries?.value(Self.textEditor(setting: router.textEditor()), priority: .userBlocking) { editor in
            if let editor { router.open(file, withApplicationAt: editor) }
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
        let router = router
        panel.begin { response in
            guard response == .OK, let app = panel.url else { return }
            router.open(file, withApplicationAt: app)
        }
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

        static var loading: String {
            String(localized: "links.menu.loading", defaultValue: "Loading…", bundle: .module)
        }

        static var revealInFinder: String {
            String(localized: "links.menu.revealInFinder", defaultValue: "Reveal in Finder", bundle: .module)
        }

        static var copyPath: String {
            String(localized: "links.menu.copyPath", defaultValue: "Copy Path", bundle: .module)
        }
    }
}
