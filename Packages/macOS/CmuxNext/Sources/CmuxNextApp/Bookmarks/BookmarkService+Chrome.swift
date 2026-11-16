import AppKit
import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextIcons
import CmuxNextSettings
import Foundation

/// The omnibar star and the bookmarks bar of every live browser chrome. The
/// service fans changes out to the chromes of the changed profile; no chrome
/// observes anything itself.
extension BookmarkService {
    /// Wires a new browser page's chrome (`TabContentCache.onBrowserEntryCreated`): its native bar
    /// reads the tab's profile through the app (``BookmarksBarHostSource``).
    func attach(_ entry: BrowserEntry) {
        let key = entry.tab.id.rawValue
        let bar = BookmarksBarView()
        bar.source = BookmarksBarHostSource(host: services, tabKey: key)
        chromes[key] = WeakChrome(entry: entry, bar: bar)
        entry.state.onPageURLChange = { [weak self, weak entry] url in if let self, let entry { updateStar(entry, url: url) } }
        entry.state.onBookmarkStar = { [weak self] anchor in self?.starPressed(tab: key, anchor: anchor) }
        updateStar(entry, url: entry.tab.state.url)
        chromes = chromes.filter { $0.value.entry != nil }
        updateBar(bar, entry: entry)
    }

    func refreshChromes(profiles: Set<String>) {
        for (key, chrome) in chromes {
            guard let entry = chrome.entry else { chromes[key] = nil; continue }
            guard profiles.contains(profile(of: entry.tab.profileID)) else { continue }
            updateStar(entry, url: entry.tab.state.url)
            updateBar(chrome.bar, entry: entry)
        }
    }

    /// `browser.showBookmarksBar` changed (cmux.json or the toggle action).
    func setBarShown(_ shown: Bool) {
        guard shown != showsBar else { return }
        showsBar = shown
        for chrome in chromes.values { if let entry = chrome.entry { updateBar(chrome.bar, entry: entry) } }
    }

    var isBarShown: Bool { showsBar }

    /// A tab's bar shows while the setting is on and its profile fills one (#38046); off its window it rebuilds when attached.
    private func updateBar(_ bar: BookmarksBarView, entry: BrowserEntry) {
        let shown = showsBar && tree(profile(of: entry.tab.profileID)).fillsBookmarksBar
        if shown { bar.reload() }
        if (entry.state.accessory?.view === bar) != shown { entry.state.accessory = shown ? (bar, BookmarksBarView.height) : nil }
    }

    /// The bar of tab `key`, for diagnostics.
    func bar(ofTab key: String) -> BookmarksBarView? { chromes[key]?.bar }

    private func updateStar(_ entry: BrowserEntry, url: URL?) {
        guard Self.canBookmark(url) else { return entry.state.bookmarkStar = .hidden }
        let bookmarked = tree(profile(of: entry.tab.profileID)).isBookmarked(url)
        entry.state.bookmarkStar = bookmarked ? .on : .off
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
        guard let anchor = anchor ?? entry.chrome.map({ $0.addressBar.bookmarkStarAnchor ?? $0.addressBar }) else { return }
        showBubble(for: node, profile: profile, isNew: isNew, anchor: anchor, tab: key)
    }

    func showBubble(for node: BookmarkNode, profile: String, isNew: Bool, anchor: NSView, tab key: String?) {
        let folders = BookmarkFolderChoice.all(in: tree(profile), barTitle: BookmarkStrings.barTitle, otherTitle: BookmarkStrings.otherBookmarks)
        let bubble = BookmarkEditBubble(
            isNew: isNew, title: node.title, folder: node.parent, folders: folders, pageTitle: { [weak self] in key.flatMap { self?.services.cache.existingBrowser($0)?.tab.state }.flatMap { $0.url?.host == node.url?.host ? $0.title : nil } },
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

extension BookmarkService {
    /// Follows `browser.showBookmarksBar` in cmux.json.
    func follow(_ settings: SettingsController) {
        // task-owner: lives as long as the service; event-driven (Observation)
        barObservation = Task { [weak self] in
            for await shown in ObservationStream({ settings.snapshot.browserShowBookmarksBar }) {
                self?.setBarShown(shown)
            }
        }
        followFolderIcons()
    }
}
