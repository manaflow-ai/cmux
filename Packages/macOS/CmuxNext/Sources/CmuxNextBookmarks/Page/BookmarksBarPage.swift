public import AppKit
import CmuxNextDesign
import CmuxNextIcons
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// What the bookmarks bar needs from the app beyond the Bookmarks page's host: the registry's
/// menus, its refusal toast, and the app's own bookmark write.
@MainActor
public protocol BookmarksBarHost: BookmarkPageHost {
    /// The registry's Bookmark menu for `bookmark` of `profile` (nil: the Bookmarks Bar menu of the
    /// bar's empty area). `isFolder` and `icon` are the row the bar drew, which the menu's rows follow.
    func bookmarkBarContextMenu(bookmark: String?, profile: String, isFolder: Bool, icon: String?) -> NSMenu?
    /// Applies a drop or a move on the bar through the app's bookmark write (the home daemon's
    /// `bookmarks.apply`), as every other bookmark edit in the app does; the star of a page the
    /// drop bookmarked turns on at once. Throws a ``PageError`` whose message says why it was refused.
    func bookmarkBarApply(_ op: BookmarkRoutedClient.Op, profile: String) async throws
    /// The owner refused a drop or a move on the bar: say why.
    func bookmarkBarRefused(_ message: String)
}

public extension PageDescriptor {
    /// The bookmarks bar (`webviews/src/pages/bookmarks-bar`): a transparent WebKit page over the
    /// native strip (``BookmarksBarHostView``), lent to the bar on screen by ``BookmarksBarPages``.
    /// `cmux.bookmarks.` goes to the daemon relay (the bar reads `children` and hears changes; it
    /// writes nothing there), `cmux.bookmarkPage.` to ``BookmarkPageHostProvider`` (profile, icons,
    /// open), and `cmux.bookmarksBar.` to ``BookmarksBarProvider`` (native menus, layout reports,
    /// drops and moves through the app). It takes the
    /// first click: a Chromium page's own window often holds the key.
    static let bookmarksBar = PageDescriptor(
        id: "cmux.bookmarks-bar", resource: "bookmarks-bar",
        namespaces: ["cmux.bookmarks.", BookmarkPageHostProvider.prefix, BookmarksBarProvider.prefix], commands: [],
        acceptsFirstMouse: true)
}

/// One bar page and its two app-side providers. The page is moved between bars; the providers
/// follow the tab it is lent to.
@MainActor
public final class BookmarksBarPage {
    public let view: PageWebView
    public let host: BookmarkPageHostProvider
    public let bar: BookmarksBarProvider

    public init(view: PageWebView, host: BookmarkPageHostProvider, bar: BookmarksBarProvider) {
        self.view = view
        self.host = host
        self.bar = bar
    }

    /// A bar page for `owner`: the tree to `relay` (the daemon's), `cmux.bookmarkPage.` to its host
    /// and `cmux.bookmarksBar.` to the bar provider. It never takes the keys from the page or the
    /// omnibar (the native bar's items did not), and it keeps the bar's own scale.
    public static func make(host owner: any BookmarksBarHost, relay: any PageProvider) -> BookmarksBarPage? {
        let host = BookmarkPageHostProvider(host: owner, tabKey: "")
        let bar = BookmarksBarProvider(host: owner, pageHost: host)
        let routes = [PageRoute(prefix: "cmux.bookmarks.", provider: relay),
                      PageRoute(prefix: BookmarkPageHostProvider.prefix, provider: host),
                      PageRoute(prefix: BookmarksBarProvider.prefix, provider: bar)]
        guard let view = PageWebView(descriptor: .bookmarksBar, routes: routes, options: engineOptions) else { return nil }
        view.refusesKeyFocus = true
        view.followsUIScale = false
        bar.page = view
        return BookmarksBarPage(view: view, host: host, bar: bar)
    }

    /// The engine options of a bar page: WebKit (it is transparent over the native strip), the first
    /// click, and no reload in place when a web update lands (the bar is always in sight).
    public static let engineOptions = PageEngineOptions(requiresWebKit: .transparentOverlay, acceptsFirstMouse: true,
                                                        keepsLoadedWeb: true)
}

/// The pages of the bookmarks bars on screen. A bar's host view borrows one when it enters a
/// window and gives it back when it leaves, so the number of pages follows the bars a person can
/// see (one per visible browser pane), not the number of tabs, and switching tabs in a pane hands
/// the same page to the next tab. At most ``maxSpare`` returned pages wait for the next bar.
@MainActor
public final class BookmarksBarPages {
    public static let maxSpare = 1
    private let make: @MainActor () -> BookmarksBarPage?
    private var spare: [BookmarksBarPage] = []
    /// Pages made since launch (diagnostics and the bar's cost bench).
    public private(set) var made = 0
    /// Pages lent to a bar now.
    public private(set) var lent = 0

    public init(make: @escaping @MainActor () -> BookmarksBarPage?) {
        self.make = make
    }

    /// A page for tab `tabKey`'s bar: a spare that last drew the same profile, else any spare, else
    /// a new one.
    func claim(tabKey: String, profile: String) -> BookmarksBarPage? {
        let index = spare.firstIndex { $0.bar.drawnProfile == profile } ?? spare.indices.first
        let page: BookmarksBarPage
        if let index {
            page = spare.remove(at: index)
        } else {
            guard let fresh = make() else { return nil }
            made += 1
            page = fresh
        }
        lent += 1
        // The new tab's bar gets no gesture made in the last one's (it gates the bar's writes),
        // and no call accepted for the last one acts in it.
        page.view.forgetUserActivation()
        page.host.tabKey = tabKey
        page.host.relend()
        return page
    }

    func giveBack(_ page: BookmarksBarPage) {
        lent -= 1
        page.view.forgetUserActivation()
        page.host.relend()
        page.bar.onLayout = nil
        page.view.removeFromSuperview()
        guard spare.count < Self.maxSpare else { return page.view.close() }
        spare.append(page)
    }
}

/// One browser tab's bookmarks bar in its chrome's accessory slot: the strip's fill, and the bar
/// page while the tab is in a window. A hidden tab's bar holds no page and does no work.
@MainActor
public final class BookmarksBarHostView: NSView {
    public static var height: CGFloat { Metrics.controlHeight + Metrics.space2 }
    public let tabKey: String
    private let pages: BookmarksBarPages
    private let profile: @MainActor () -> String
    private(set) var page: BookmarksBarPage?
    /// What the page last showed on this bar (``BookmarksBarProvider/Layout``).
    public private(set) var shown = BookmarksBarProvider.Layout()

    public init(tabKey: String, pages: BookmarksBarPages, profile: @escaping @MainActor () -> String) {
        self.tabKey = tabKey
        self.pages = pages
        self.profile = profile
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        setAccessibilityIdentifier("cmux.bookmarks.bar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated public override var isFlipped: Bool { true }
    nonisolated public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        performWithTheme { layer?.backgroundColor = Palette.paneFill.cgColor }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        followVisibility()
    }

    // A parked pane hides its chrome (`isHidden`) without leaving the window: that bar gives its
    // page back too, so pages follow the bars a person can see. AppKit calls these for a hidden or
    // shown ancestor as well.
    public override func viewDidHide() {
        super.viewDidHide()
        followVisibility()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        followVisibility()
    }

    private func followVisibility() {
        if window != nil, !isHiddenOrHasHiddenAncestor { borrow() } else { giveBack() }
    }

    /// The page this bar shows now, nil while its tab is hidden (diagnostics and tests).
    public var pageView: PageWebView? { page?.view }

    /// Item titles in bar order, visible first (diagnostics, `debug.bookmarks`).
    public var visibleTitles: [String] { shown.visible.map(\.title) }
    public var overflowTitles: [String] { shown.overflow }

    /// Bookmark `id`'s item on this bar in screen coordinates, for popups that open beside it (the
    /// App's icon picker). Nil when the bar is not in a window or `id` is not an item shown on it.
    public func itemFrameOnScreen(_ id: String) -> NSRect? {
        guard let window, let item = shown.visible.first(where: { $0.id == id }) else { return nil }
        let rect = NSRect(x: item.x, y: (bounds.height - Metrics.controlHeight) / 2, width: item.width, height: Metrics.controlHeight)
        return window.convertToScreen(convert(rect, to: nil))
    }

    private func borrow() {
        guard page == nil else { return }
        let profile = profile()
        guard let page = pages.claim(tabKey: tabKey, profile: profile) else { return }
        self.page = page
        // Another profile's row must not show for a frame: the page shows once it laid out this
        // tab's row (the strip's fill stands in, as the native bar's did before its tree loaded).
        // A page that last drew this profile reports nothing new (its row did not change): the
        // bar takes its last report, so item frames and menu anchors are this page's. The report
        // is the one record of what the page drew, kept while the page waits as a spare too.
        let drawnHere = page.bar.drawnProfile == profile
        page.view.alphaValue = drawnHere ? 1 : 0
        if drawnHere, let last = page.bar.lastLayout { shown = last }
        page.bar.onLayout = { [weak self, weak page] layout in
            // A report for the profile the page drew before it came here is stale: the page stays
            // hidden until it reports this tab's profile.
            guard let self, let page, self.page === page, let drawn = layout.profile, drawn == self.profile() else { return }
            shown = layout
            page.view.alphaValue = 1
        }
        page.view.frame = bounds
        page.view.autoresizingMask = [.width, .height]
        addSubview(page.view)
    }

    private func giveBack() {
        guard let page else { return }
        self.page = nil
        shown = BookmarksBarProvider.Layout()
        pages.giveBack(page)
    }
}

/// Serves `cmux.bookmarksBar.*` to one bar page:
///
/// - `menu {profile, lend, title, anchor: {x, y, width, height}, rows}`: a folder's native menu under `anchor`
///   (CSS px). Rows are `{kind: "bookmark", id, title, url, favicon_key?}`, `{kind: "folder", id,
///   title, icon?, children, partial?}`, `{kind: "openAll", folder, title}`, `{kind: "empty", title}` and
///   `{kind: "separator"}`; a submenu is filled when it opens. A `partial` folder (its read was cut
///   short) shows what was read and asks the page for its rows as it opens (`folderRows`, host to
///   page, `{profile, lend, folder}` → `{rows}`). A picked row opens from the tab the bar is in (a
///   native menu choice is the person's own act).
/// - `contextMenu {bookmark?, kind?, icon?, point: {x, y}}`: the registry's Bookmark menu (its rows
///   follow the drawn row's kind and icon), or the Bookmarks Bar menu for the bar's empty area.
/// - `layout {profile, visible: [{id, title, x, width}], overflow: [title]}`: what the bar shows
///   for `profile`; the bar view drops a report for a profile it does not show.
/// - `apply {op}`: a link dropped on the bar (`{op: "create", parent: "bar", index, title, url}`)
///   or an item moved along it (`{op: "move", bookmark, parent: "bar", index}`), written by the
///   app (``BookmarksBarHost/bookmarkBarApply(_:profile:)``) on the person's gesture, one write
///   per gesture.
/// - `refused {message}`: a drop or a move was refused, or never reached the app.
@MainActor
public final class BookmarksBarProvider: PageProvider {
    public static let prefix = "cmux.bookmarksBar."
    /// Host to page: a `partial` folder's rows, read when its submenu opens.
    static let folderRowsOp = prefix + "folderRows"

    public struct Item: Equatable, Sendable {
        public var id: String
        public var title: String
        public var x: CGFloat
        public var width: CGFloat
    }

    public struct Layout: Equatable, Sendable {
        /// The profile whose row the page laid out.
        public var profile: String?
        public var visible: [Item] = []
        public var overflow: [String] = []
        public init() {}
    }

    private weak var host: (any BookmarksBarHost)?
    private let pageHost: BookmarkPageHostProvider
    public weak var page: PageWebView?
    var onLayout: (@MainActor (Layout) -> Void)?
    /// The page's last layout report, held or spare (the page sends one only when its row changes):
    /// the one record of what the page drew.
    public private(set) var lastLayout: Layout?
    /// The profile whose row the page drew last (its last layout report's).
    public var drawnProfile: String? { lastLayout?.profile }
    /// The menu on screen and its rows' folders (kept while it is open).
    private var openMenu: BookmarksBarMenu?
    /// The gesture the last write spent (one write per key or pointer event).
    private var spentGesture: TimeInterval?

    public init(host: any BookmarksBarHost, pageHost: BookmarkPageHostProvider) {
        self.host = host
        self.pageHost = pageHost
    }

    /// The bar's write `op` (a create or a move on the bar root) as the daemon's op, or nil for
    /// anything else.
    static func operation(_ op: JSONValue, profile: String) -> BookmarkRoutedClient.Op? {
        let bar = BookmarkRoot.bar.rawValue
        guard op["parent"]?.stringValue == bar, let index = op["index"]?.intValue, index >= 0 else { return nil }
        switch op["op"]?.stringValue {
        case "move":
            guard let id = op["bookmark"]?.stringValue else { return nil }
            return .move(id: id, parent: bar, index: index)
        case "create":
            guard let text = op["url"]?.stringValue, let url = URL(string: text) else { return nil }
            return .create(id: BookmarkID.make(), profile: profile, parent: bar, index: index, folder: false,
                           title: op["title"]?.stringValue ?? "", url: url)
        default:
            return nil
        }
    }

    /// Whether `operation` keeps to the bar whose items are `bar` (the profile's own, read from the daemon,
    /// never the page's word): a create at a slot of it, or a move of one of its items to another.
    static func staysOnBar(_ operation: BookmarkRoutedClient.Op, bar: [BookmarkNode]) -> Bool {
        let op = operation.json
        guard op["parent"]?.stringValue == BookmarkRoot.bar.rawValue, let index = op["index"]?.intValue else { return false }
        switch op["op"]?.stringValue {
        case "create":
            return index <= bar.count
        case "move":
            guard let id = op["bookmark"]?.stringValue else { return false }
            return bar.contains { $0.id == id } && index < bar.count
        default:
            return false
        }
    }

    /// Whether a `menu` call's rows were read for this page's profile, on its current lend.
    func acceptsMenu(_ params: JSONValue) -> Bool {
        params["profile"]?.stringValue == pageHost.profile && params["lend"]?.intValue == pageHost.lendGeneration
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let host else { throw PageError.closed }
        switch op {
        case Self.prefix + "menu":
            // Rows read for the profile the page drew before it was lent here would open that
            // profile's bookmarks in this tab: dropped.
            // So would rows read before the page was lent again, to a tab of the same profile.
            guard let page, let anchor = params["anchor"], acceptsMenu(params),
                  let rows = params["rows"]?.arrayValue.map(BookmarksBarMenu.rows) else { return .object([:]) }
            let number = { (key: String) in CGFloat(anchor[key]?.doubleValue ?? 0) }
            let lease = pageHost.lease()
            // The page may be lent to another tab while the menu is open: a pick then does nothing.
            let isCurrent: @MainActor () -> Bool = { [weak pageHost] in pageHost?.isCurrent(lease) ?? false }
            let ask = params
            // A cut folder's rows come from the page, for the profile and lend its menu was read on.
            let load: BookmarksBarMenu.Load = { [weak page] folder in
                guard let page, isCurrent() else { return nil }
                let reply = try? await page.router.callPage(Self.folderRowsOp, params: .object([
                    "profile": ask["profile"] ?? .null, "lend": ask["lend"] ?? .null, "folder": .string(folder),
                ]))
                guard isCurrent(), let rows = reply?["rows"]?.arrayValue else { return nil }
                return BookmarksBarMenu.rows(rows)
            }
            let menu = BookmarksBarMenu(host: host, profile: lease.profile, tabKey: lease.tabKey, rows: rows,
                                        title: params["title"]?.stringValue ?? "", isCurrent: isCurrent, load: load)
            openMenu = menu
            defer { if openMenu === menu { openMenu = nil } }
            await page.presentMenu(menu.menu, atPagePoint: CGPoint(x: number("x"), y: number("y") + number("height") + 2))
            return .object([:])
        case Self.prefix + "contextMenu":
            guard let page, let point = params["point"] else { return .object([:]) }
            let bookmark = params["bookmark"]?.stringValue
            let made = host.bookmarkBarContextMenu(bookmark: bookmark, profile: pageHost.profile,
                                                   isFolder: params["kind"]?.stringValue == "folder", icon: params["icon"]?.stringValue)
            guard let menu = made?.themeRows(in: page.themeScope.fullStrength) else {
                return .object([:])
            }
            await page.presentMenu(menu, atPagePoint: CGPoint(x: point["x"]?.doubleValue ?? 0, y: point["y"]?.doubleValue ?? 0))
            return .object([:])
        case Self.prefix + "layout":
            var layout = Layout()
            layout.profile = params["profile"]?.stringValue
            layout.visible = (params["visible"]?.arrayValue ?? []).compactMap { item in
                guard let id = item["id"]?.stringValue else { return nil }
                return Item(id: id, title: item["title"]?.stringValue ?? "", x: CGFloat(item["x"]?.doubleValue ?? 0),
                            width: CGFloat(item["width"]?.doubleValue ?? 0))
            }
            layout.overflow = (params["overflow"]?.arrayValue ?? []).compactMap(\.stringValue)
            lastLayout = layout
            onLayout?(layout)
            return .object([:])
        case Self.prefix + "apply":
            guard context.userGesture, let event = context.gestureEvent, event != spentGesture else {
                throw PageError(code: PageNativeOp.userOnlyCode, message: "A bookmarks bar edit needs a click or a drop.")
            }
            let lease = pageHost.lease()
            guard let operation = params["op"].flatMap({ Self.operation($0, profile: lease.profile) }) else {
                throw PageError.invalidParams("a create on the bookmarks bar, or a move of one of its items along it")
            }
            spentGesture = event
            // The bar's own row, read from the daemon (never the page's word), bounds the write.
            let bar = try await host.bookmarkChildren(of: BookmarkRoot.bar.rawValue, profile: lease.profile)
            try pageHost.requireCurrent(lease, op)
            guard Self.staysOnBar(operation, bar: bar) else {
                throw PageError.invalidParams("a create on the bookmarks bar, or a move of one of its items along it")
            }
            try await host.bookmarkBarApply(operation, profile: lease.profile)
            return .object([:])
        case Self.prefix + "refused":
            host.bookmarkBarRefused(params["message"]?.stringValue ?? "")
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }
}

/// A folder's native menu from the rows the bar page read (the bar's folders, the chevron's
/// overflow, Other Bookmarks): one `NSMenu` per folder, each filled when it opens, so a large
/// subtree costs nothing until the person walks into it.
@MainActor
final class BookmarksBarMenu: NSObject, NSMenuDelegate {
    indirect enum Row {
        case bookmark(BookmarkNode)
        /// A folder and its rows; `partial` when its read was cut short (the rest is read on open).
        case folder(BookmarkNode, [Row], partial: Bool = false)
        case openAll(String, title: String)
        case empty(String)
        case separator
    }

    private weak var host: (any BookmarksBarHost)?
    private let profile: String
    private let tabKey: String
    /// Whether the bar that opened the menu still shows `profile` in tab `tabKey`.
    private let isCurrent: @MainActor () -> Bool
    /// Reads a folder's rows from the page (nil: the read failed or the bar moved on).
    typealias Load = @MainActor (String) async -> [Row]?

    private var rows: [Row]
    private var children: [BookmarksBarMenu] = []
    /// The folder whose rows were cut short, read once when this menu first opens.
    private var partial: String?
    private let load: Load?
    /// The read of `partial`'s rows under way (awaited by tests).
    private(set) var loading: Task<Void, Never>?
    let menu: NSMenu

    init(host: any BookmarksBarHost, profile: String, tabKey: String, rows: [Row], title: String,
         partial: String? = nil, isCurrent: @escaping @MainActor () -> Bool = { true }, load: Load? = nil) {
        self.host = host
        self.profile = profile
        self.tabKey = tabKey
        self.isCurrent = isCurrent
        self.rows = rows
        self.partial = partial
        self.load = load
        menu = NSMenu(title: title)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    /// The rows of the page's `rows` array.
    static func rows(_ values: [JSONValue]) -> [Row] {
        values.compactMap { value in
            let title = value["title"]?.stringValue ?? ""
            switch value["kind"]?.stringValue {
            case "bookmark":
                guard let id = value["id"]?.stringValue, let url = value["url"]?.stringValue.flatMap(URL.init(string:)) else { return nil }
                return .bookmark(BookmarkNode(id: id, parent: "", kind: .url, title: title, url: url,
                                              faviconKey: value["favicon_key"]?.stringValue))
            case "folder":
                guard let id = value["id"]?.stringValue else { return nil }
                return .folder(BookmarkNode(id: id, parent: "", kind: .folder, title: title, icon: value["icon"]?.stringValue),
                               rows(value["children"]?.arrayValue ?? []), partial: value["partial"]?.boolValue ?? false)
            case "openAll":
                guard let folder = value["folder"]?.stringValue else { return nil }
                return .openAll(folder, title: title)
            case "empty":
                return .empty(title)
            case "separator":
                return .separator
            default:
                return nil
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu)
        // A cut folder shows what was read at once and its whole level once the page answers.
        guard let folder = partial, let load, loading == nil else { return }
        loading = Task { [weak self] in
            let rows = await load(folder)
            guard let self else { return }
            loading = nil
            guard let rows, isCurrent() else { return }
            partial = nil
            self.rows = rows
            fill(self.menu)
        }
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        children.removeAll()
        guard let host else { return }
        if rows.isEmpty, partial != nil {
            // Nothing of a cut folder was read yet: its rows land here when the page answers.
            let item = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let side = Metrics.smallIconSize
        for row in rows {
            switch row {
            case .bookmark(let node):
                // The rows of the native BookmarkFolderMenu this replaces, as they were.
                let item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
                item.target = self
                item.action = #selector(open(_:))
                item.representedObject = node.id
                item.toolTip = node.url.map { "\(node.title)\n\($0.absoluteString)" }
                item.image = host.bookmarkFavicon(node, profile: profile).map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) }
                    ?? NSImage.icon(.browser, size: side)
                menu.addItem(item)
            case .folder(let node, let rows, let partial):
                let item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
                item.image = host.bookmarkFolderIcon(node, side: side) ?? NSImage.icon(.folder, size: side)
                let child = BookmarksBarMenu(host: host, profile: profile, tabKey: tabKey, rows: rows, title: node.title,
                                             partial: partial ? node.id : nil, isCurrent: isCurrent, load: load)
                children.append(child)
                item.submenu = child.menu
                menu.addItem(item)
            case .openAll(let folder, let title):
                let item = NSMenuItem(title: title, action: #selector(openAll(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = folder
                menu.addItem(item)
            case .empty(let title):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            }
        }
    }

    private var links: [BookmarkNode] {
        rows.compactMap { if case .bookmark(let node) = $0 { node } else { nil } }
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard let host, isCurrent(), let id = sender.representedObject as? String,
              let node = links.first(where: { $0.id == id }) else { return }
        host.openBookmark(node, profile: profile, disposition: .from(NSApp.currentEvent?.modifierFlags ?? []), fromTab: tabKey)
    }

    /// Every link directly in the folder: the first in a new tab, the rest behind it.
    @objc private func openAll(_ sender: NSMenuItem) {
        guard let host, isCurrent() else { return }
        for (index, node) in links.enumerated() {
            host.openBookmark(node, profile: profile, disposition: index == 0 ? .newTab : .backgroundTab, fromTab: tabKey)
        }
    }
}
