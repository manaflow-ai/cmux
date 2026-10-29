import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextCompat
import Foundation
import os
import CmuxNextWakeups

/// Chromium's bookmark models follow cmux's trees: the chrome.bookmarks bridge
/// (plans/cmux-next/bookmarks.md section 4). A Chromium store asks for its
/// first sync when its model loads; every change of a profile's tree syncs
/// each store of that profile; an extension's change in Chromium is applied to
/// cmux's tree as an ordinary operation, so the sync that follows finds
/// nothing to change. cmux wins: a change cmux refuses is undone in Chromium
/// by syncing the store again. Ids: `bm_<32 hex>` in cmux is that UUID in
/// Chromium; the roots are `bar` and `other` on both sides.
///
/// Syncs are debounced per store, and each event from a store pushes its
/// sync back: Chromium's events are posted, so a sync sent while an
/// extension's later change is still queued would undo that change. A store
/// whose cmux tree is not loaded yet waits, and is synced once it is.
final class BookmarkChromiumSync {
    static let settle: Duration = .milliseconds(400)
    /// Weak: the service owns this sync; after it is gone every entry point returns.
    private weak var service: BookmarkService?
    private let bridge = CEFBookmarkBridge.shared
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "bookmarks")
    /// Store to its cmux profile, for stores whose sync waits for the tree to load.
    private var waiting: [String: String] = [:]
    /// Each store's settle, then its sync in idle time. `background`: Chromium's model serves extensions,
    /// which nobody watches redraw.
    private let settles: BookmarkSyncSettle
    private var homeObservation: ServiceObservation<String>?

    init(service: BookmarkService) {
        self.service = service
        let mainWork = service.mainWork
        settles = BookmarkSyncSettle(settle: Self.settle, maxDelay: Self.idleMaxDelay,
                                     deadlines: service.mainDeadlines) { owner, maxDelay, body in
            mainWork.postIdle(owner: owner, maxDelay: maxDelay) { _ in body() }
        }
        bridge.onEvent = { [weak self] profile, store, event in
            self?.handle(event, profile: BrowserProfileRecord.wireID(for: profile), store: store)
        }
        // The file becomes the truth once the home daemon answered or gave
        // up; a reconnect lets a failed read start again. A service: the
        // stores sync whether or not a browser tab shows.
        let home = service.machines.local
        homeObservation = ServiceObservation(.background, owner: "BookmarkChromiumSync.home", on: mainWork) {
            "\(home.store.identity != nil) \(home.startup) \(home.store.connectionState)"
        } apply: { [weak self] _ in
            self?.retryWaiting()
        }
        // A store that loaded before this sync existed (it starts after the reveal,
        // `LaunchStart.bookmarkSync`) asked for its first sync with no one listening.
        for (engine, stores) in bridge.stores {
            for store in stores { schedule(store, profile: BrowserProfileRecord.wireID(for: engine)) }
        }
    }

    /// `profiles` changed in cmux (`BookmarkService.changed`).
    func treesChanged(_ profiles: Set<String>) {
        for (engine, stores) in bridge.stores {
            let profile = BrowserProfileRecord.wireID(for: engine)
            guard profiles.contains(profile) else { continue }
            for store in stores { schedule(store, profile: profile) }
        }
        retryWaiting()
    }

    /// Syncs the waiting stores whose tree is loaded; reading the others
    /// starts their fetch again when one failed or found no connection.
    private func retryWaiting() {
        guard let service else { return }
        for (store, profile) in waiting {
            if service.isLoaded(profile) { schedule(store, profile: profile) } else { _ = service.tree(profile) }
        }
    }

    private func handle(_ event: CEFBookmarkEvent, profile: String, store: String) {
        guard let service else { return }
        // Chromium is still changing this store: its sync waits until it settles.
        defer { schedule(store, profile: profile) }
        // Before cmux's tree is loaded a change would land on an empty
        // placeholder; the sync after the load wins instead (cmux wins at start).
        guard service.isLoaded(profile) else {
            waiting[store] = profile
            _ = service.tree(profile)
            return
        }
        do {
            switch event {
            case .loaded, .reset:
                break
            case .added(let nodes):
                for node in nodes { try create(node, profile: profile) }
            case .changed(let id, let title, let url):
                var parsed: URL?
                if let url {
                    guard let value = URL(string: url) else { throw BookmarkChromiumSyncError.badURL }
                    parsed = value
                }
                try service.apply(.update(id: Self.cmuxID(id), title: title, url: parsed), profile: profile)
            case .moved(let id, let parent, let index):
                try service.apply(.move(id: Self.cmuxID(id), parent: Self.cmuxID(parent), index: index), profile: profile)
            case .removed(let id):
                let id = Self.cmuxID(id)
                if service.tree(profile).node(id) != nil { try service.apply(.delete(id: id), profile: profile) }
            case .reordered(let parent, let children):
                for (index, child) in children.enumerated() where service.tree(profile).index(of: Self.cmuxID(child)) != index {
                    try service.apply(.move(id: Self.cmuxID(child), parent: Self.cmuxID(parent), index: index), profile: profile)
                }
            }
        } catch {
            // The deferred sync puts cmux's tree back in Chromium.
            logger.error("chrome.bookmarks change refused: \(String(describing: error), privacy: .public)")
        }
    }

    private func create(_ node: CEFBookmarkNode, profile: String) throws {
        guard let service else { return }
        let id = Self.cmuxID(node.id), parent = Self.cmuxID(node.parent)
        guard service.tree(profile).node(id) == nil else { return }
        let created = node.addedMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        // An extension's bookmark is not the person's choice of folder for the star.
        let lastFolder = service.lastFolder[profile]
        defer { service.lastFolder[profile] = lastFolder }
        if node.isFolder {
            try service.apply(.create(.folder(node.title, in: parent, id: id, created: created), index: node.index), profile: profile)
        } else {
            guard let url = node.url.flatMap(URL.init(string:)) else { throw BookmarkChromiumSyncError.badURL }
            try service.apply(.create(.bookmark(node.title, url: url, in: parent, id: id, created: created), index: node.index),
                              profile: profile)
        }
    }

    /// Syncs `store` in the main thread's idle time once its events have
    /// settled for `settle`; a later call starts the wait again. The sync
    /// serializes the whole tree, which is idle work (``BookmarkSyncSettle``).
    private func schedule(_ store: String, profile: String) {
        settles.schedule(store) { [weak self] in self?.sync(store, profile: profile) }
    }

    /// The longest a settled sync waits for idle time before it runs as background work.
    static let idleMaxDelay: Duration = .seconds(2)

    /// Syncs once cmux's tree of `profile` is loaded: a sync before would
    /// empty Chromium's model. Reading the tree starts its fetch, whose
    /// `changed` comes back here.
    private func sync(_ store: String, profile: String) {
        guard let service else { return }
        guard service.isLoaded(profile) else {
            waiting[store] = profile
            _ = service.tree(profile)
            return
        }
        waiting[store] = nil
        // The reason tells a refusal (the store is forgotten) from no answer in time (it stays).
        bridge.sync(store: store, treeJSON: Self.json(service.tree(profile))) { [logger] failure in
            logger.error("chrome.bookmarks sync not applied (\(String(describing: failure), privacy: .public)) for a store of \(profile, privacy: .public)")
        }
    }

    /// {"nodes": [...]} in the tree's preorder.
    static func json(_ tree: BookmarkTree) -> String {
        let nodes: [[String: Any]] = tree.ordered.map { node in
            var object: [String: Any] = [
                "id": chromiumID(node.id), "parent": chromiumID(node.parent),
                "kind": node.isFolder ? "folder" : "url", "title": node.title,
                "added_ms": BookmarkTime.ms(node.created),
            ]
            if let url = node.url { object["url"] = url.absoluteString }
            return object
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["nodes": nodes])) ?? Data("{\"nodes\":[]}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// `bm_<32 hex>` as a lowercase UUID; roots unchanged.
    static func chromiumID(_ id: String) -> String {
        guard BookmarkID.isValid(id) else { return id }
        let hex = Array(id.dropFirst(3))
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }.joined(separator: "-")
    }

    /// A Chromium UUID as `bm_<32 hex>`; roots unchanged.
    static func cmuxID(_ id: String) -> String {
        guard !BookmarkRoot.isRoot(id) else { return id }
        return "bm_" + id.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

enum BookmarkChromiumSyncError: Error {
    case badURL
}
