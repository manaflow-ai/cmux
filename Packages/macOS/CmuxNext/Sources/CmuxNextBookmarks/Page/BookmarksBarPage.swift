public import AppKit
import CmuxNextDesign
import CmuxNextIcons
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// What the bookmarks bar needs from the app beyond the Bookmarks page's host: the registry's
/// menus and its refusal toast.
@MainActor
public protocol BookmarksBarHost: BookmarkPageHost {
    /// The registry's Bookmark menu for `bookmark` (nil: the Bookmarks Bar menu of the bar's empty area).
    func bookmarkBarContextMenu(bookmark: String?) -> NSMenu?
    /// The owner refused a drop or a move on the bar: say why.
    func bookmarkBarRefused(_ message: String)
}

public extension PageDescriptor {
    /// The bookmarks bar (`webviews/src/pages/bookmarks-bar`): a transparent WebKit page over the
    /// native strip (``BookmarksBarHostView``), lent to the bar on screen by ``BookmarksBarPages``.
    /// `cmux.bookmarks.` goes to the daemon relay (the bar may read `children` and apply on a
    /// gesture), `cmux.bookmarkPage.` to ``BookmarkPageHostProvider`` (profile, icons, open), and
    /// `cmux.bookmarksBar.` to ``BookmarksBarProvider`` (native menus, layout reports). It takes the
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
        page.host.tabKey = tabKey
        return page
    }

    func giveBack(_ page: BookmarksBarPage) {
        lent -= 1
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
        if window != nil { borrow() } else { giveBack() }
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
        page.view.alphaValue = page.bar.drawnProfile == profile ? 1 : 0
        page.bar.onLayout = { [weak self, weak page] layout in
            guard let self, let page, self.page === page else { return }
            shown = layout
            page.bar.drawnProfile = self.profile()
            page.view.alphaValue = 1
        }
        page.view.frame = bounds
        page.view.autoresizingMask = [.width, .height]
        addSubview(page.view)
    }

    private func giveBack() {
        guard let page else { return }
        self.page = nil
        pages.giveBack(page)
    }
}

/// Serves `cmux.bookmarksBar.*` to one bar page:
///
/// - `menu {title, anchor: {x, y, width, height}, rows}`: a folder's native menu under `anchor`
///   (CSS px). Rows are `{kind: "bookmark", id, title, url, favicon_key?}`, `{kind: "folder", id,
///   title, icon?, children}`, `{kind: "openAll", folder, title}`, `{kind: "empty", title}` and
///   `{kind: "separator"}`; a submenu is filled when it opens. A picked row opens from the tab
///   the bar is in (a native menu choice is the person's own act).
/// - `contextMenu {bookmark?, point: {x, y}}`: the registry's Bookmark menu, or the Bookmarks
///   Bar menu for the bar's empty area.
/// - `layout {visible: [{id, title, x, width}], overflow: [title]}`: what the bar shows.
/// - `refused {message}`: the owner refused a drop or a move.
@MainActor
public final class BookmarksBarProvider: PageProvider {
    public static let prefix = "cmux.bookmarksBar."

    public struct Item: Equatable, Sendable {
        public var id: String
        public var title: String
        public var x: CGFloat
        public var width: CGFloat
    }

    public struct Layout: Equatable, Sendable {
        public var visible: [Item] = []
        public var overflow: [String] = []
        public init() {}
    }

    private weak var host: (any BookmarksBarHost)?
    private let pageHost: BookmarkPageHostProvider
    public weak var page: PageWebView?
    /// The profile whose row the page drew last (set by the bar view on each layout).
    public var drawnProfile: String?
    var onLayout: (@MainActor (Layout) -> Void)?
    /// The menu on screen and its rows' folders (kept while it is open).
    private var openMenu: BookmarksBarMenu?

    public init(host: any BookmarksBarHost, pageHost: BookmarkPageHostProvider) {
        self.host = host
        self.pageHost = pageHost
    }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let host else { throw PageError.closed }
        switch op {
        case Self.prefix + "menu":
            guard let page, let anchor = params["anchor"],
                  let rows = params["rows"]?.arrayValue.map(BookmarksBarMenu.rows) else { return .object([:]) }
            let number = { (key: String) in CGFloat(anchor[key]?.doubleValue ?? 0) }
            let menu = BookmarksBarMenu(host: host, profile: pageHost.profile, tabKey: pageHost.tabKey, rows: rows,
                                        title: params["title"]?.stringValue ?? "")
            openMenu = menu
            defer { if openMenu === menu { openMenu = nil } }
            await page.presentMenu(menu.menu, atPagePoint: CGPoint(x: number("x"), y: number("y") + number("height") + 2))
            return .object([:])
        case Self.prefix + "contextMenu":
            guard let page, let point = params["point"] else { return .object([:]) }
            let bookmark = params["bookmark"]?.stringValue
            guard let menu = host.bookmarkBarContextMenu(bookmark: bookmark)?.themeRows(in: page.themeScope.fullStrength) else {
                return .object([:])
            }
            await page.presentMenu(menu, atPagePoint: CGPoint(x: point["x"]?.doubleValue ?? 0, y: point["y"]?.doubleValue ?? 0))
            return .object([:])
        case Self.prefix + "layout":
            var layout = Layout()
            layout.visible = (params["visible"]?.arrayValue ?? []).compactMap { item in
                guard let id = item["id"]?.stringValue else { return nil }
                return Item(id: id, title: item["title"]?.stringValue ?? "", x: CGFloat(item["x"]?.doubleValue ?? 0),
                            width: CGFloat(item["width"]?.doubleValue ?? 0))
            }
            layout.overflow = (params["overflow"]?.arrayValue ?? []).compactMap(\.stringValue)
            onLayout?(layout)
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
        case folder(BookmarkNode, [Row])
        case openAll(String, title: String)
        case empty(String)
        case separator
    }

    private weak var host: (any BookmarksBarHost)?
    private let profile: String
    private let tabKey: String
    private let rows: [Row]
    private var children: [BookmarksBarMenu] = []
    let menu: NSMenu

    init(host: any BookmarksBarHost, profile: String, tabKey: String, rows: [Row], title: String) {
        self.host = host
        self.profile = profile
        self.tabKey = tabKey
        self.rows = rows
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
                               rows(value["children"]?.arrayValue ?? []))
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
        menu.removeAllItems()
        children.removeAll()
        guard let host else { return }
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
            case .folder(let node, let rows):
                let item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
                item.image = host.bookmarkFolderIcon(node, side: side) ?? NSImage.icon(.folder, size: side)
                let child = BookmarksBarMenu(host: host, profile: profile, tabKey: tabKey, rows: rows, title: node.title)
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
        guard let host, let id = sender.representedObject as? String, let node = links.first(where: { $0.id == id }) else { return }
        host.openBookmark(node, profile: profile, disposition: .from(NSApp.currentEvent?.modifierFlags ?? []), fromTab: tabKey)
    }

    /// Every link directly in the folder: the first in a new tab, the rest behind it.
    @objc private func openAll(_ sender: NSMenuItem) {
        guard let host else { return }
        for (index, node) in links.enumerated() {
            host.openBookmark(node, profile: profile, disposition: index == 0 ? .newTab : .backgroundTab, fromTab: tabKey)
        }
    }
}
