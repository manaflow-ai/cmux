public import AppKit
import CmuxNextCompat
public import CmuxNextPages
public import CmuxNextSettings
import Foundation

/// What the Bookmarks page needs from the app (``BookmarkPageHostProvider``): the profile a tab
/// shows, the tree the app mirrors, icons and opening a page.
@MainActor
public protocol BookmarkPageHost: AnyObject, Sendable {
    func bookmarkProfile(ofTab key: String) -> String
    func bookmarkTree(_ profile: String) -> BookmarkTree
    var bookmarkFolderIconsSupported: Bool { get }
    /// A URL bookmark's favicon (fetched when missing), nil while it loads or without one.
    func bookmarkFavicon(_ node: BookmarkNode, profile: String) -> CGImage?
    /// A folder's own icon at `side` points; nil without one or while a stored one loads.
    func bookmarkFolderIcon(_ node: BookmarkNode, side: CGFloat) -> NSImage?
    /// Read under observation: changes when a favicon or a stored folder icon lands.
    var bookmarkIconRevision: Int { get }
    func openBookmark(_ node: BookmarkNode, profile: String, disposition: BookmarkOpenDisposition, fromTab key: String)
    func openAllBookmarks(in folder: String, profile: String, fromTab key: String)
}

public extension PageDescriptor {
    /// The Bookmarks manager page (`webviews/src/pages/bookmarks`): the tree is the daemon's
    /// routed `bookmarks.*` namespace (`cmux.bookmarks.`, through the page relay); the app serves
    /// only the profile, the root titles, the icons and opening a page (`cmux.bookmarkPage.`,
    /// ``BookmarkPageHostProvider``), and the file and icon steps run as registry actions.
    static let bookmarks = PageDescriptor(
        id: "cmux.bookmarks", resource: "bookmarks", namespaces: ["cmux.bookmarks.", BookmarkPageHostProvider.prefix],
        nativeOps: [PageNativeOp.actionRun, PageNativeOp.clipboardWrite],
        actions: ["bookmark.import", "bookmark.importFromBrowser", "bookmark.export", "bookmark.setIcon", "bookmark.clearIcon"],
        commands: PageNativeOp.commands.union([BookmarkPageHostProvider.revealCommand]), ownsSearchField: true)
}

/// Serves `cmux.bookmarkPage.*` to one Bookmarks page:
///
/// - `state {}`: `{browser_profile_id, bar_title, other_title, can_set_folder_icons}`.
/// - stream `changed`: `{reason: "state"}` when the page's profile changed (re-read the state, then
///   the tree), `{reason: "icons"}` when a favicon or stored folder icon landed (ask again for the
///   icons that were missing). One event per main-actor turn.
/// - `icons {ids}`: `{icons: {id: dataURL}, masks: [id]}`, the favicons and folder icons of the rows
///   on screen; an id in `masks` is a symbol drawn as a template the page tints.
/// - `open {bookmark, disposition}` and `openAll {folder}`: as from the bookmarks bar.
@MainActor
public final class BookmarkPageHostProvider: PageProvider {
    public static let prefix = "cmux.bookmarkPage."
    public static let changedStream = "cmux.bookmarkPage.changed"
    /// The page command that shows one bookmark (`{bookmark}`).
    public static let revealCommand = "reveal"
    /// Most icons one `icons` call answers (the rows on screen).
    private static let maxIcons = 200
    /// Icon edge in pixels (rows draw 16 pt at 2x).
    private static let iconSide: CGFloat = 32

    private weak var host: (any BookmarkPageHost)?
    public let tabKey: String
    /// A top page names its profile (its window's workspace); a tab page uses the tab's.
    public var profileOverride: (@MainActor () -> String)?
    private var listeners: [UUID: @MainActor (JSONValue) -> Void] = [:]
    private var pending: Set<String> = []
    private var servedProfile: String?
    private var iconObservation: Task<Void, Never>?

    public init(host: any BookmarkPageHost, tabKey: String) {
        self.host = host
        self.tabKey = tabKey
    }

    public var profile: String { profileOverride?() ?? host?.bookmarkProfile(ofTab: tabKey) ?? "default" }

    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        guard let host else { throw PageError.closed }
        switch op {
        case Self.prefix + "state":
            let profile = profile
            servedProfile = profile
            return .object([
                "browser_profile_id": .string(profile), "bar_title": .string(BookmarkStrings.barTitle),
                "other_title": .string(BookmarkStrings.otherBookmarks),
                "can_set_folder_icons": .bool(host.bookmarkFolderIconsSupported),
            ])
        case Self.prefix + "icons":
            return icons(params["ids"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        case Self.prefix + "open":
            guard let node = node(params["bookmark"]) else { throw PageError(code: "cmux.bookmarkPage.not_found", message: op) }
            let disposition: BookmarkOpenDisposition = switch params["disposition"]?.stringValue {
            case "newTab": .newTab
            case "backgroundTab": .backgroundTab
            default: .currentTab
            }
            host.openBookmark(node, profile: profile, disposition: disposition, fromTab: tabKey)
            return .object([:])
        case Self.prefix + "openAll":
            guard let node = node(params["folder"]), node.isFolder else {
                throw PageError(code: "cmux.bookmarkPage.not_found", message: op)
            }
            host.openAllBookmarks(in: node.id, profile: profile, fromTab: tabKey)
            return .object([:])
        default:
            throw PageError.unknownOp(op)
        }
    }

    public func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                   onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
        guard stream == Self.changedStream else { throw PageError.unknownOp(stream) }
        let id = UUID()
        listeners[id] = onEvent
        followIcons()
        return PageSubscription { [weak self] in
            guard let self else { return }
            listeners[id] = nil
            if listeners.isEmpty { stopFollowingIcons() }
        }
    }

    public func pageDidClose() {
        listeners.removeAll()
        stopFollowingIcons()
    }

    /// The page shows again: a top page whose window moved to a workspace of another profile
    /// re-reads its state.
    public func pageShown() {
        guard let servedProfile, servedProfile != profile else { return }
        post("state")
    }

    private func node(_ id: JSONValue?) -> BookmarkNode? {
        id?.stringValue.flatMap { host?.bookmarkTree(profile).node($0) }
    }

    private func icons(_ ids: [String]) -> JSONValue {
        guard let host else { return .null }
        let tree = host.bookmarkTree(profile)
        var icons: [String: JSONValue] = [:]
        var masks: [JSONValue] = []
        for id in ids.prefix(Self.maxIcons) {
            guard let node = tree.node(id) else { continue }
            if node.isFolder {
                guard let image = host.bookmarkFolderIcon(node, side: Self.iconSide) else { continue }
                guard let url = Self.dataURL(image) else { continue }
                icons[id] = .string(url)
                if image.isTemplate { masks.append(.string(id)) }
            } else if let url = host.bookmarkFavicon(node, profile: profile).flatMap(Self.dataURL) {
                icons[id] = .string(url)
            }
        }
        return .object(["icons": .object(icons), "masks": .array(masks)])
    }

    private static func dataURL(_ image: NSImage) -> String? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil).flatMap(dataURL)
    }

    private static func dataURL(_ image: CGImage) -> String? {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    /// Tells the page when a favicon or a stored folder icon lands, while it listens (no polling).
    private func followIcons() {
        guard iconObservation == nil, let host else { return }
        // task-owner: lives while the page listens (stopFollowingIcons); event-driven (Observation)
        iconObservation = Task { [weak self] in
            var first = true
            for await _ in ObservationStream({ [weak host] in host?.bookmarkIconRevision ?? 0 }) {
                // The stream's first value is the state at subscribe, not a change.
                if first { first = false; continue }
                self?.post("icons")
            }
        }
    }

    private func stopFollowingIcons() {
        iconObservation?.cancel()
        iconObservation = nil
    }

    private func post(_ reason: String) {
        guard !listeners.isEmpty, pending.insert(reason).inserted, pending.count == 1 else { return }
        // task-owner: one coalesced event per main-actor turn; ends at once
        Task { [weak self] in
            guard let self else { return }
            let reasons = pending
            pending.removeAll()
            for reason in reasons.sorted() {
                for listener in listeners.values { listener(.object(["reason": .string(reason)])) }
            }
        }
    }
}
