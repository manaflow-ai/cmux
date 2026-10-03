import AppKit
import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextSettings
import Foundation

/// The omnibar star and the bookmarks bar of every live browser chrome. The
/// service fans changes out to the chromes of the changed profile; no chrome
/// observes anything itself.
extension BookmarkService {
    /// Wires a new browser page's chrome (`TabContentCache.onBrowserEntryCreated`).
    func attach(_ entry: BrowserEntry) {
        let key = entry.tab.id.rawValue
        let adapter = BookmarkBarSourceAdapter(service: self, tabKey: key)
        let bar = BookmarksBarView()
        bar.source = adapter
        chromes[key] = WeakChrome(entry: entry, bar: bar, source: adapter)
        entry.chrome.addressBar.onPageURLChange = { [weak self, weak entry] url in
            guard let self, let entry else { return }
            updateStar(entry, url: url)
        }
        entry.chrome.addressBar.onBookmarkStar = { [weak self] anchor in self?.starPressed(tab: key, anchor: anchor) }
        updateStar(entry, url: entry.tab.state.url)
        entry.chrome.setAccessoryView(showsBar ? bar : nil, height: BookmarksBarView.height)
        chromes = chromes.filter { $0.value.entry != nil }
    }

    func refreshChromes(profiles: Set<String>) {
        for (key, chrome) in chromes {
            guard let entry = chrome.entry else {
                chromes[key] = nil
                continue
            }
            guard profiles.contains(profile(of: entry.tab.profileID)) else { continue }
            updateStar(entry, url: entry.tab.state.url)
            if showsBar { chrome.bar.reload() }
        }
    }

    /// `browser.showBookmarksBar` changed (cmux.json or the toggle action).
    func setBarShown(_ shown: Bool) {
        guard shown != showsBar else { return }
        showsBar = shown
        for chrome in chromes.values {
            guard let entry = chrome.entry else { continue }
            if shown { chrome.bar.reload() }
            entry.chrome.setAccessoryView(shown ? chrome.bar : nil, height: BookmarksBarView.height)
        }
    }

    var isBarShown: Bool { showsBar }

    /// The bar of tab `key`, for diagnostics.
    func bar(ofTab key: String) -> BookmarksBarView? { chromes[key]?.bar }

    private func updateStar(_ entry: BrowserEntry, url: URL?) {
        guard Self.canBookmark(url) else { return entry.chrome.addressBar.setBookmarkStar(.hidden) }
        let bookmarked = tree(profile(of: entry.tab.profileID)).isBookmarked(url)
        entry.chrome.addressBar.setBookmarkStar(bookmarked ? .on : .off)
    }

    /// Pages that can be bookmarked: anything with a scheme except blank,
    /// data and the New Tab page.
    static func canBookmark(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), !["about", "data", "javascript"].contains(scheme) else { return false }
        return !BrowserNewTabPage.isNewTabPage(url)
    }

    // MARK: Star and bubble

    /// The star (or Bookmark This Page): bookmarks the page in the last-used
    /// folder if it is not yet bookmarked, then opens the edit bubble.
    func starPressed(tab key: String, anchor: NSView?) {
        if let open = BookmarkEditBubble.current, open.isShown { return open.close() }
        guard let entry = services.cache.existingBrowser(key), let url = entry.tab.state.url, Self.canBookmark(url) else {
            return services.registry.refuse(BookmarkAppStrings.cannotBookmark)
        }
        let profile = profile(of: entry.tab.profileID)
        var isNew = false
        var node = tree(profile).bookmarks(for: url).first
        if node == nil {
            let created = BookmarkNode.bookmark(entry.tab.state.title ?? "", url: url, in: defaultFolder(profile: profile))
            do { try apply(.create(created, index: nil), profile: profile) } catch {
                return services.registry.refuse(BookmarkAppStrings.failure(error))
            }
            node = created
            isNew = true
        }
        guard let node else { return }
        let anchor = anchor ?? entry.chrome.addressBar.bookmarkStarAnchor ?? entry.chrome.addressBar
        showBubble(for: node, profile: profile, isNew: isNew, anchor: anchor, tab: key)
    }

    func showBubble(for node: BookmarkNode, profile: String, isNew: Bool, anchor: NSView, tab key: String?) {
        let folders = BookmarkFolderChoice.all(in: tree(profile), barTitle: BookmarkStrings.barTitle, otherTitle: BookmarkStrings.otherBookmarks)
        let bubble = BookmarkEditBubble(
            isNew: isNew, title: node.title, folder: node.parent, folders: folders,
            onSave: { [weak self] result in
                guard let self, let current = tree(profile).node(node.id) else { return }
                if result.title != current.title { try? apply(.update(id: node.id, title: result.title), profile: profile) }
                if result.folder != current.parent {
                    try? apply(.move(id: node.id, parent: result.folder, index: tree(profile).children(of: result.folder).count),
                               profile: profile)
                    lastFolder[profile] = result.folder
                }
            },
            onRemove: { [weak self] in
                guard let self, let url = node.url else { return }
                for bookmark in tree(profile).bookmarks(for: url) { try? apply(.delete(id: bookmark.id), profile: profile) }
            },
            onMore: { [weak self] in self?.services.bookmarkPages.open(selecting: node.id) })
        bubble.show(relativeTo: anchor)
    }
}

/// One chrome's bar source: the tab's browser profile, opens from that tab.
@MainActor
final class BookmarkBarSourceAdapter: BookmarksBarSource {
    private weak var service: BookmarkService?
    let tabKey: String

    init(service: BookmarkService, tabKey: String) {
        self.service = service
        self.tabKey = tabKey
    }

    private var profile: String { service?.profile(ofTab: tabKey) ?? BrowserProfileRecord.defaultID }

    func bookmarkChildren(of parent: String) -> [BookmarkNode] { service?.tree(profile).children(of: parent) ?? [] }

    func favicon(for node: BookmarkNode) -> NSImage? {
        NSImage(systemSymbolName: node.isFolder ? "folder" : "globe", accessibilityDescription: nil)
    }

    func open(_ node: BookmarkNode, disposition: BookmarkOpenDisposition) {
        guard let service else { return }
        BookmarkOpener(services: service.services).open(node, profile: profile, disposition: disposition, fromTab: tabKey)
    }

    func openAll(in folder: String) {
        guard let service else { return }
        BookmarkOpener(services: service.services).openAll(in: folder, profile: profile, fromTab: tabKey)
    }

    func moveToBar(_ id: String, index: Int) {
        try? service?.apply(.move(id: id, parent: BookmarkRoot.bar.rawValue, index: index), profile: profile)
    }

    func addToBar(url: URL, title: String, index: Int) {
        try? service?.apply(.create(.bookmark(title, url: url, in: BookmarkRoot.bar.rawValue), index: index), profile: profile)
    }

    func contextMenu(for node: BookmarkNode?) -> NSMenu? {
        guard let registry = service?.services.registry else { return nil }
        // The bar belongs to a browser tab: Bookmark This Page there is available.
        guard let node else { return registry.makeContextMenu(for: .bookmarksBar, implied: .browserFocused) }
        return registry.makeContextMenu(for: .bookmark, target: ActionTargetRef(kind: .bookmark, id: node.id), implied: .browserFocused)
    }
}

extension BookmarkService {
    /// Follows `browser.showBookmarksBar` in cmux.json.
    func follow(_ settings: SettingsController) {
        // task-owner: lives as long as the service; event-driven (Observation)
        barObservation = Task { [weak self] in
            for await shown in Observations({ settings.snapshot.browserShowBookmarksBar }) {
                self?.setBarShown(shown)
            }
        }
    }
}
