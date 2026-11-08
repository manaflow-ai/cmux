import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextCompat
import Foundation
import os
import CmuxNextWakeups

/// Chromium's bookmark models follow the home daemon's trees: the chrome.bookmarks bridge
/// (plans/cmux-next/bookmarks.md section 4). A Chromium store asks for its first sync when its
/// model loads; every change of a profile's tree syncs each store of that profile from a
/// `bookmarks.list` read; an extension's change in Chromium goes to the daemon as an ordinary op,
/// so the sync that follows finds nothing to change. cmux wins: a change the daemon refuses is
/// undone in Chromium by syncing the store again. Ids: `bm_<32 hex>` in cmux is that UUID in
/// Chromium; the roots are `bar` and `other` on both sides.
///
/// Syncs are debounced per store, and each event from a store pushes its sync back: Chromium's
/// events are posted, so a sync sent while an extension's later change is still queued would undo
/// that change. Events go to the daemon one after another, in the order Chromium posted them. A
/// store whose tree cannot be read yet (no home daemon) waits and syncs once it can.
final class BookmarkChromiumSync {
    static let settle: Duration = .milliseconds(400)
    /// Weak: the service owns this sync; after it is gone every entry point returns.
    private weak var service: BookmarkService?
    private let bridge = CEFBookmarkBridge.shared
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "bookmarks")
    /// Store to its cmux profile, for stores whose sync waits for the home daemon.
    private var waiting: [String: String] = [:]
    private var scheduled: [String: DemandTimer] = [:]
    /// The last event's write: the next one starts after it (Chromium's order).
    private var writes: Task<Void, Never>?
    private var homeObservation: Task<Void, Never>?

    init(service: BookmarkService) {
        self.service = service
        bridge.onEvent = { [weak self] profile, store, event in
            self?.handle(event, profile: BrowserProfileRecord.wireID(for: profile), store: store)
        }
        // task-owner: lives as long as the service; event-driven (Observation). A daemon that
        // starts serving bookmarks syncs the stores that waited for it.
        homeObservation = Task { [weak self, weak service] in
            for await serves in ObservationStream({ ObservationTrigger(service?.usesDaemon ?? false) }) {
                guard let self else { return }
                if serves.value { retryWaiting() }
            }
        }
    }

    /// `profiles` changed in the daemon (``BookmarkService/daemonChanged(_:)``).
    func treesChanged(_ profiles: Set<String>) {
        for (engine, stores) in bridge.stores {
            let profile = BrowserProfileRecord.wireID(for: engine)
            guard profiles.contains(profile) else { continue }
            for store in stores { schedule(store, profile: profile) }
        }
    }

    private func retryWaiting() {
        for (store, profile) in waiting { schedule(store, profile: profile) }
    }

    private func handle(_ event: CEFBookmarkEvent, profile: String, store: String) {
        // Chromium is still changing this store: its sync waits until it settles.
        defer { schedule(store, profile: profile) }
        guard let service, service.usesDaemon else {
            waiting[store] = profile
            return
        }
        let ops: [BookmarkRoutedClient.Op]
        do { ops = try Self.ops(for: event, profile: profile) } catch {
            return logger.error("chrome.bookmarks change refused: \(String(describing: error), privacy: .public)")
        }
        guard !ops.isEmpty else { return }
        let previous = writes
        // task-owner: one Chromium event's ops, after the previous event's; ends with its reply
        writes = Task { [weak self, weak service] in
            await previous?.value
            do { try await service?.apply(ops) } catch {
                // The deferred sync puts the daemon's tree back in Chromium.
                self?.logger.error("chrome.bookmarks change refused: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The daemon's ops for one Chromium event. A create of an id the daemon has changes
    /// nothing; a delete or move of one it lacks is refused and the sync puts Chromium back.
    static func ops(for event: CEFBookmarkEvent, profile: String) throws -> [BookmarkRoutedClient.Op] {
        switch event {
        case .loaded, .reset:
            return []
        case .added(let nodes):
            return try nodes.map { node in
                let created = node.addedMs.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
                var url: URL?
                if !node.isFolder {
                    guard let parsed = node.url.flatMap(URL.init(string:)) else { throw BookmarkChromiumSyncError.badURL }
                    url = parsed
                }
                return .create(id: cmuxID(node.id), profile: profile, parent: cmuxID(node.parent), index: node.index,
                               folder: node.isFolder, title: node.title, url: url, created: created)
            }
        case .changed(let id, let title, let url):
            var parsed: URL?
            if let url {
                guard let value = URL(string: url) else { throw BookmarkChromiumSyncError.badURL }
                parsed = value
            }
            return [.update(id: cmuxID(id), title: title, url: parsed)]
        case .moved(let id, let parent, let index):
            return [.move(id: cmuxID(id), parent: cmuxID(parent), index: index)]
        case .removed(let id):
            return [.delete(id: cmuxID(id))]
        case .reordered(let parent, let children):
            return children.enumerated().map { index, child in .move(id: cmuxID(child), parent: cmuxID(parent), index: index) }
        }
    }

    /// Syncs `store` once its events have settled for `settle`; a later call starts the wait again.
    private func schedule(_ store: String, profile: String) {
        // One debounce per store: a later schedule replaces the pending deadline.
        let timer = scheduled[store] ?? DemandTimer(owner: "BookmarkChromiumSync.settle")
        scheduled[store] = timer
        timer.schedule(after: Self.settle) { @MainActor [weak self] in
            self?.sync(store, profile: profile)
        }
    }

    /// Syncs from the daemon's tree, read now (after the events written so far); a store whose
    /// tree cannot be read waits for the daemon (a sync before would empty Chromium's model).
    private func sync(_ store: String, profile: String) {
        guard let service, service.usesDaemon else {
            waiting[store] = profile
            return
        }
        let routed = service.routed, pending = writes
        // task-owner: one bookmarks.list read and one sync; ends with them
        Task { [weak self] in
            await pending?.value
            guard let self else { return }
            do {
                let nodes = try await routed.list(profile: profile)
                waiting[store] = nil
                if bridge.sync(store: store, treeJSON: Self.json(nodes)) < 0 {
                    logger.error("chrome.bookmarks sync refused for a store of \(profile, privacy: .public)")
                }
            } catch {
                waiting[store] = profile
            }
        }
    }

    /// {"nodes": [...]} in listing order (each folder before its children).
    static func json(_ ordered: [BookmarkNode]) -> String {
        let nodes: [[String: Any]] = ordered.map { node in
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
