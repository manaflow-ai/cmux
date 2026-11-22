public import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// One browser tab's bar source over the app (``BookmarksBarHost``): the tab's browser profile,
/// the app's tree of it, and opens from that tab. The same model path as the star and the
/// Bookmarks page.
@MainActor
public final class BookmarksBarHostSource: BookmarksBarSource {
    private weak var host: (any BookmarksBarHost)?
    public let tabKey: String
    /// The nodes the last bar build (and its menus since) drew a stand-in icon for, by id.
    private var standIns: [String: BookmarkNode] = [:]

    public init(host: any BookmarksBarHost, tabKey: String) {
        self.host = host
        self.tabKey = tabKey
    }

    private var profile: String { host?.bookmarkProfile(ofTab: tabKey) ?? "default" }

    public func bookmarkChildren(of parent: String) -> [BookmarkNode] {
        // A bar build reads the children, then each icon: it waits again only if an icon does.
        if parent == BookmarkRoot.bar.rawValue { standIns.removeAll() }
        return host?.bookmarkTree(profile).children(of: parent) ?? []
    }

    public func favicon(for node: BookmarkNode) -> NSImage? {
        let side = Metrics.smallIconSize
        if let image = ownIcon(of: node, side: side) { return image }
        // A link, or a folder with an icon of its own, may get its icon later.
        if !node.isFolder || node.icon != nil { standIns[node.id] = node }
        return NSImage.icon(node.isFolder ? .folder : .browser, size: side)
    }

    public var awaitedIconsLanded: Bool {
        guard let host else { return false }
        // Read under observation, with no stand-in too: the next build may draw one.
        _ = host.bookmarkIconRevision
        return standIns.values.contains { ownIcon(of: $0, side: Metrics.smallIconSize) != nil }
    }

    /// A folder's own icon (`bookmark-icon-v1`) or a link's favicon; nil without one or while it loads.
    private func ownIcon(of node: BookmarkNode, side: CGFloat) -> NSImage? {
        guard let host else { return nil }
        if node.isFolder { return host.bookmarkFolderIcon(node, side: side) }
        return host.bookmarkFavicon(node, profile: profile).map { NSImage(cgImage: $0, size: NSSize(width: side, height: side)) }
    }

    public func open(_ node: BookmarkNode, disposition: BookmarkOpenDisposition) {
        host?.openBookmark(node, profile: profile, disposition: disposition, fromTab: tabKey)
    }

    public func openAll(in folder: String) {
        guard let host else { return }
        let profile = profile
        // The first in a new tab, the rest behind it.
        for (index, node) in host.bookmarkTree(profile).children(of: folder).filter({ !$0.isFolder }).enumerated() {
            host.openBookmark(node, profile: profile, disposition: index == 0 ? .newTab : .backgroundTab, fromTab: tabKey)
        }
    }

    public func moveToBar(_ id: String, index: Int) {
        host?.bookmarkBarApply(.move(id: id, parent: BookmarkRoot.bar.rawValue, index: index), profile: profile)
    }

    public func addToBar(url: URL, title: String, index: Int) {
        host?.bookmarkBarApply(.create(.bookmark(title, url: url, in: BookmarkRoot.bar.rawValue), index: index), profile: profile)
    }

    public func contextMenu(for node: BookmarkNode?) -> NSMenu? { host?.bookmarkBarContextMenu(bookmark: node?.id) }
}
