import CmuxNextBookmarks
import CmuxNextBrowser
import Foundation
import os

/// Chromium's bookmark models follow cmux's trees: the chrome.bookmarks bridge
/// (plans/cmux-next/bookmarks.md section 4). A Chromium store asks for its
/// first sync when its model loads; every change of a profile's tree syncs
/// each store of that profile; an extension's change in Chromium is applied to
/// cmux's tree as an ordinary operation, so the sync that follows finds
/// nothing to change. cmux wins: a change cmux refuses is undone in Chromium
/// by syncing the store again. Ids: `bm_<32 hex>` in cmux is that UUID in
/// Chromium; the roots are `bar` and `other` on both sides.
final class BookmarkChromiumSync {
    private unowned let service: BookmarkService
    private let bridge = CEFBookmarkBridge.shared
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "bookmarks")

    init(service: BookmarkService) {
        self.service = service
        bridge.onEvent = { [weak self] profile, store, event in
            self?.handle(event, profile: BrowserProfileRecord.wireID(for: profile), store: store)
        }
    }

    /// `profiles` changed in cmux (`BookmarkService.changed`).
    func treesChanged(_ profiles: Set<String>) {
        for (engine, stores) in bridge.stores {
            let profile = BrowserProfileRecord.wireID(for: engine)
            guard profiles.contains(profile) else { continue }
            for store in stores { sync(store, profile: profile) }
        }
    }

    private func handle(_ event: CEFBookmarkEvent, profile: String, store: String) {
        // Before cmux's tree is loaded a change would land on an empty
        // placeholder; the sync after the load wins instead (cmux wins at start).
        guard service.isLoaded(profile) || event == .loaded || event == .reset else {
            _ = service.tree(profile)
            return
        }
        do {
            switch event {
            case .loaded, .reset:
                sync(store, profile: profile)
            case .added(let nodes):
                for node in nodes { try create(node, profile: profile) }
            case .changed(let id, let title, let url):
                try service.apply(.update(id: Self.cmuxID(id), title: title, url: url.flatMap(URL.init(string:))), profile: profile)
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
            logger.error("chrome.bookmarks change refused: \(String(describing: error), privacy: .public)")
            sync(store, profile: profile)
        }
    }

    private func create(_ node: CEFBookmarkNode, profile: String) throws {
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

    /// Syncs once cmux's tree of `profile` is loaded: a sync before would
    /// empty Chromium's model. Reading the tree starts its fetch, whose
    /// `changed` comes back here.
    private func sync(_ store: String, profile: String) {
        let tree = service.tree(profile)
        guard service.isLoaded(profile) else { return }
        if bridge.sync(store: store, treeJSON: Self.json(tree)) < 0 {
            logger.error("chrome.bookmarks sync refused for a store of \(profile, privacy: .public)")
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
