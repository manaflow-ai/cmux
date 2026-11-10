import AppKit
import CmuxNextActions
import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextSettings
import Foundation

/// The omnibar star and the bookmarks bar of every live browser chrome. The service fans changes
/// out to the chromes of the changed profile; no chrome observes anything itself. Both read the
/// status cache (``statuses``), never a tree.
extension BookmarkService {
    /// Wires a new browser page's chrome (`TabContentCache.onBrowserEntryCreated`). Its bar is only
    /// a strip until the tab is in a window: then it borrows a bar page (``barPages``).
    func attach(_ entry: BrowserEntry) {
        let key = entry.tab.id.rawValue
        let bar = BookmarksBarHostView(tabKey: key, pages: barPages, profile: { [weak self] in
            self?.profile(ofTab: key) ?? BrowserProfileRecord.defaultID
        })
        chromes[key] = WeakChrome(entry: entry, bar: bar)
        entry.state.onPageURLChange = { [weak self, weak entry] url in if let self, let entry { updateStar(entry, url: url) } }
        entry.state.onBookmarkStar = { [weak self] anchor in self?.starPressed(tab: key, anchor: anchor) }
        chromes = chromes.filter { $0.value.entry != nil }
        updateStar(entry, url: entry.tab.state.url)
        updateBar(bar, entry: entry)
        if !statuses.knows(profile(of: entry.tab.profileID)) { refreshStatus(profile(of: entry.tab.profileID)) }
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

    /// A tab's bar shows while the setting is on and its profile fills one (#38046). Its page reads
    /// the daemon's rows itself and follows their changes: the app only attaches or detaches it.
    private func updateBar(_ bar: BookmarksBarHostView, entry: BrowserEntry) {
        let shown = showsBar && statuses.barFilled(profile(of: entry.tab.profileID))
        if (entry.state.accessory?.view === bar) != shown { entry.state.accessory = shown ? (bar, BookmarksBarHostView.height) : nil }
    }

    /// The bar of tab `key`, for diagnostics.
    func bar(ofTab key: String) -> BookmarksBarHostView? { chromes[key]?.bar }

    /// The star of a page whose status is known shows it at once; a new page's is read (one
    /// `bookmarks.status` for the profile's pages on screen) and shows when it lands.
    private func updateStar(_ entry: BrowserEntry, url: URL?) {
        guard let url, Self.canBookmark(url) else { return entry.state.bookmarkStar = .hidden }
        let profile = profile(of: entry.tab.profileID)
        guard let ids = bookmarkIDs(for: url, profile: profile) else {
            if entry.state.bookmarkStar == .hidden { entry.state.bookmarkStar = .off }
            return refreshStatus(profile)
        }
        entry.state.bookmarkStar = ids.isEmpty ? .off : .on
    }

    /// Pages that can be bookmarked: anything with a scheme except blank,
    /// data and the New Tab page.
    static func canBookmark(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), !["about", "data", "javascript"].contains(scheme) else { return false }
        return !BrowserNewTabPage.isNewTabPage(url)
    }

    // MARK: Star and bubble

    /// The star (or Bookmark This Page): bookmarks the page in the last-used folder if it is not
    /// yet bookmarked, then opens the edit bubble. The star turns on in the same frame; the
    /// daemon's reply and the folder choices come before the bubble opens.
    func starPressed(tab key: String, anchor: NSView?) {
        if let open = BookmarkEditBubble.current, open.isShown { return open.close() }
        guard let entry = services.cache.existingBrowser(key), let url = entry.tab.state.url, Self.canBookmark(url) else {
            return services.registry.refuse(BookmarkAppStrings.cannotBookmark)
        }
        guard usesDaemon else {
            return services.registry.refuse(unavailable.message)
        }
        guard let anchor = anchor ?? entry.chrome.map({ $0.addressBar.bookmarkStarAnchor ?? $0.addressBar }) else { return }
        let profile = profile(of: entry.tab.profileID)
        let title = entry.tab.state.title ?? ""
        let known = bookmarkIDs(for: url, profile: profile)
        // task-owner: one star press: a status read, a create or a row read, and the folders; ends with the bubble
        Task { [weak self, weak anchor] in
            guard let self else { return }
            do {
                var ids = known ?? []
                if known == nil { ids = try await routed.status(profile: profile, urls: [url.absoluteString]).matches[url.absoluteString] ?? [] }
                var node: BookmarkNode?
                if let id = ids.first { node = try await routed.get([id], profile: profile).first }
                var isNew = false
                if node == nil {
                    node = try await create(title: title, url: url, profile: profile)
                    isNew = true
                }
                guard let node, let anchor else { return }
                showBubble(for: node, profile: profile, isNew: isNew, anchor: anchor, tab: key)
            } catch {
                refreshStatus(profile)
                services.registry.refuse(BookmarkAppStrings.failure(error))
            }
        }
    }

    /// A new link for the page in the last folder used (the bar when that one is gone). The star
    /// turns on before the daemon answers; a refusal reads the status again.
    private func create(title: String, url: URL, profile: String) async throws -> BookmarkNode {
        let id = BookmarkID.make()
        noteBookmarks([id], url: url, profile: profile, barFilled: true)
        let folder = try await starFolder(profile: profile) { try await self.routed.get([$0], profile: profile).first?.isFolder == true }
        try await apply([.create(id: id, profile: profile, parent: folder, folder: false, title: title, url: url)])
        return BookmarkNode(id: id, parent: folder, kind: .url, title: title, url: url)
    }

    /// The last folder used while `isFolder` finds it, else the bar, forgetting it (a gone parent is refused as `invalid`).
    func starFolder(profile: String, isFolder: (String) async throws -> Bool) async throws -> String {
        guard let last = lastFolder[profile], !BookmarkRoot.isRoot(last) else { return lastFolder[profile] ?? BookmarkRoot.bar.rawValue }
        if try await isFolder(last) { return last }
        if lastFolder[profile] == last { lastFolder[profile] = nil }
        return BookmarkRoot.bar.rawValue
    }

    /// The edit bubble on `node`, with the daemon's folder choices.
    func showBubble(for node: BookmarkNode, profile: String, isNew: Bool, anchor: NSView, tab key: String?) {
        // task-owner: one bookmarks.folders read; ends with the bubble
        Task { [weak self, weak anchor] in
            guard let self else { return }
            let folders: BookmarkRoutedClient.JSONValue
            do { folders = try await routed.folders(profile: profile) } catch {
                return services.registry.refuse(BookmarkAppStrings.failure(error))
            }
            guard let anchor else { return }
            let bubble = BookmarkEditBubble(
                isNew: isNew, title: node.title, folder: node.parent, folders: folders,
                pageTitle: { [weak self] in key.flatMap { self?.services.cache.existingBrowser($0)?.tab.state }.flatMap { $0.url?.host == node.url?.host ? $0.title : nil } },
                onSave: { [weak self] result in self?.save(result, of: node, profile: profile) },
                onRemove: { [weak self] in self?.removeAll(like: node, profile: profile) },
                onMore: { [weak self] in self?.services.bookmarkPages.open(selecting: node.id) })
            bubble.show(relativeTo: anchor)
        }
    }

    /// The bubble's Done or dismiss: a rename and a move to the end of the folder chosen.
    private func save(_ result: BookmarkEditBubble.Result, of node: BookmarkNode, profile: String) {
        var ops: [BookmarkRoutedClient.Op] = []
        if result.title != node.title { ops.append(.update(id: node.id, title: result.title)) }
        if result.folder != node.parent {
            // An index past the end appends (the daemon clamps it).
            ops.append(.move(id: node.id, parent: result.folder, index: Int(Int32.max)))
            lastFolder[profile] = result.folder
        }
        guard !ops.isEmpty else { return }
        run(ops)
    }

    /// The bubble's Remove: every link to the page goes, as the star shows them all as one.
    private func removeAll(like node: BookmarkNode, profile: String) {
        guard let url = node.url else { return }
        noteBookmarks([], url: url, profile: profile)
        // task-owner: one status read and the delete batches in turn; ends with their replies
        Task { [weak self] in
            guard let self else { return }
            do {
                let ids = try await routed.status(profile: profile, urls: [url.absoluteString]).matches[url.absoluteString] ?? [node.id]
                try await BookmarkRoutedClient.inBatches(ids.map { .delete(id: $0) }) { try await self.apply($0) }
            } catch {
                refreshStatus(profile)
                services.registry.refuse(BookmarkAppStrings.failure(error))
            }
        }
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
