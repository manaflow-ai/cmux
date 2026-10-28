import CmuxNextBookmarks
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

/// The home daemon side (`bookmarks-v1`): fetches on demand, refetches on
/// `bookmarks-changed`, writes each operation as its command, and copies the
/// local file into the daemon once it serves the capability.
extension BookmarkService {
    /// Follows the home daemon's capability: when it appears, copy the file
    /// over and switch every tree to the daemon's; when it goes (an older
    /// daemon after a downgrade), fall back to the file.
    ///
    /// A trigger: a daemon restart that still serves bookmarks resets and
    /// fetches again. `visible`: the bars and stars show the trees it loads.
    func observeHome() {
        guard let services else { return }
        homeObservation = ServiceObservation(.visible, owner: "BookmarkService.home", on: services.mainWork) { [weak self] in
            ObservationTrigger(self?.usesDaemon ?? false)
        } apply: { [weak self] serves in
            self?.switchHome(serves: serves.value)
        }
    }

    /// One switch at a time, in order: the copy and the reads run off main, each main step is one posted task, and
    /// a step of a switch a later change replaced does nothing.
    func switchHome(serves: Bool) {
        guard let services else { return }
        homeGeneration &+= 1
        let generation = homeGeneration, previous = homeSwitch, mainWork = services.mainWork
        // task-owner: the service's one switch at a time; each waits for the one before it
        homeSwitch = Task { @concurrent [weak self] in
            await previous?.value
            guard let self else { return }
            let copies = await mainWork.apply(.visible, owner: "BookmarkService.homeReset") { () -> Bool in
                self.resetHome(serves: serves, generation: generation)
            }
            guard copies else { return }
            await self.copyFileToDaemon()
            let reading = await mainWork.apply(.visible, owner: "BookmarkService.homeSettled") { () -> [Task<Void, Never>]? in
                guard generation == self.homeGeneration else { return nil }
                self.homeSettled = true
                return Array(self.fetching.values)
            }
            guard let reading else { return }
            // A read started during the copy saw part of it: read again once it ends.
            for read in reading { await read.value }
            await mainWork.apply(.visible, owner: "BookmarkService.homeRefetch") { () -> Void in
                guard generation == self.homeGeneration else { return }
                for profile in Set(self.trees.keys).union([BrowserProfileRecord.defaultID]) { self.fetch(profile) }
            }
        }
    }

    /// The switch's copy step: ``homeCopy`` when set, else ``migrateFileToDaemon()``.
    private func copyFileToDaemon() async {
        if let homeCopy { await homeCopy() } else { await migrateFileToDaemon() }
    }

    /// Forgets the daemon's reads for a capability change; true when the file copies into the daemon next.
    private func resetHome(serves: Bool, generation: UInt64) -> Bool {
        guard generation == homeGeneration else { return false }
        fetched.removeAll()
        loadedFromDaemon.removeAll()
        homeSettled = false
        if !serves, fileLoaded {
            trees = fileTrees.mapValues(BookmarkTree.init(ordered:))
            changed(profiles: Set(trees.keys))
        }
        return serves
    }

    /// Reads `profile`'s tree from the daemon (one request in flight per profile).
    func fetch(_ profile: String) {
        guard let services else { return }
        guard fetching[profile] == nil, let connection = services.machines.local.connection else { return }
        fetched.insert(profile)
        let complete = homeSettled
        // task-owner: one list-bookmarks read; ends with its reply
        fetching[profile] = Task { [weak self] in
            defer { self?.fetching[profile] = nil }
            do {
                let list = try await connection.listBookmarks(browserProfileID: profile)
                guard let self else { return }
                trees[profile] = BookmarkTree(ordered: list.bookmarks.map(Self.node(from:)))
                if complete { loadedFromDaemon.insert(profile) }
                changed(profiles: [profile])
            } catch {
                self?.fetched.remove(profile)
                self?.logger.error("list-bookmarks \(profile, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    func daemonChanged(_ profile: String) {
        guard usesDaemon else { return }
        fetching[profile]?.cancel()
        fetching[profile] = nil
        fetch(profile)
    }

    /// Writes one operation to the daemon. The local tree already shows it;
    /// the daemon's `bookmarks-changed` replaces it with the stored truth,
    /// and a refused write refetches. One mutation key per logical write
    /// (the daemon's exactly-once ledger replays a retried key).
    func send(_ operation: BookmarkOperation, profile: String) {
        guard let services else { return }
        let home = services.machines.local
        let mutationID = UUID().uuidString.lowercased()
        // task-owner: one bookmark command; a failure refetches the profile
        Task { [weak self] in
            let ok = await home.run("bookmark") { connection in
                try await Self.perform(operation, profile: profile, mutationID: mutationID, on: connection)
            }
            if !ok { self?.daemonChanged(profile) }
        }
    }

    /// Sends `operation` with the exactly-once key `mutationID` (a create
    /// that also sets last use sends a second write keyed `<id>.used`).
    nonisolated static func perform(_ operation: BookmarkOperation, profile: String, mutationID: String,
                                    on connection: DaemonConnection) async throws {
        let key = MutationIdentity(origin: DaemonConnection.origin, mutationID: mutationID)
        switch operation {
        case .create(let node, let index):
            try await connection.createBookmark(CreateBookmarkRequest(
                bookmark: node.id, browserProfileID: profile, parent: node.parent, index: index, kind: node.kind.rawValue,
                title: node.title, url: node.url?.absoluteString, faviconKey: node.faviconKey, sourceKey: node.sourceKey,
                createdMs: BookmarkTime.ms(node.created), mutation: key))
            if let lastUsed = node.lastUsed {
                try await connection.updateBookmark(UpdateBookmarkRequest(
                    bookmark: node.id, lastUsedMs: .set(BookmarkTime.ms(lastUsed)),
                    mutation: MutationIdentity(origin: DaemonConnection.origin, mutationID: mutationID + ".used")))
            }
        case .update(let id, let title, let url, let favicon, let lastUsed, let icon):
            try await connection.updateBookmark(UpdateBookmarkRequest(
                bookmark: id, title: title, url: url?.absoluteString, faviconKey: fieldUpdate(favicon) { $0 },
                lastUsedMs: fieldUpdate(lastUsed) { BookmarkTime.ms($0) }, icon: fieldUpdate(icon) { $0 }, mutation: key))
        case .move(let id, let parent, let index):
            try await connection.moveBookmark(id, parent: parent, index: index, mutation: key)
        case .delete(let id):
            try await connection.deleteBookmark(id, mutation: key)
        case .importDrafts(let parent, let index, let sourceKey, let replace, let drafts):
            try await connection.importBookmarks(ImportBookmarksRequest(
                browserProfileID: profile, parent: parent, index: index, sourceKey: sourceKey, replace: replace ? true : nil,
                nodes: drafts.map(importNode), mutation: key))
        }
    }

    nonisolated static func importNode(_ draft: BookmarkDraft) -> BookmarkImportNode {
        BookmarkImportNode(kind: draft.kind.rawValue, title: draft.title, url: draft.url?.absoluteString,
                           createdMs: draft.created.map(BookmarkTime.ms),
                           children: draft.kind == .folder ? draft.children.map(importNode) : nil)
    }

    nonisolated static func fieldUpdate<V, W>(_ change: BookmarkFieldChange<V>, _ map: (V) -> W) -> FieldUpdate<W> {
        switch change {
        case .unchanged: .unchanged
        case .clear: .clear
        case .set(let value): .set(map(value))
        }
    }

    nonisolated static func node(from record: BookmarkRecord) -> BookmarkNode {
        BookmarkNode(id: record.id, parent: record.parent, kind: BookmarkNode.Kind(rawValue: record.kind) ?? .url, title: record.title,
                     url: record.url.flatMap(URL.init(string:)), faviconKey: record.faviconKey, sourceKey: record.sourceKey,
                     created: BookmarkTime.date(ms: record.createdMs), lastUsed: record.lastUsedMs.map(BookmarkTime.date(ms:)),
                     icon: record.icon)
    }

    /// Copies this Mac's file into the daemon, node by node in tree order
    /// (parents first) with the same ids: a create with an existing id is a
    /// no-op there, so an interrupted copy resumes. Deletes the file after.
    func migrateFileToDaemon() async {
        guard let services else { return }
        guard !migrating, let file, await file.exists, let connection = services.machines.local.connection else { return }
        migrating = true
        defer { migrating = false }
        do {
            for (profile, nodes) in await file.load() {
                var indexes: [String: Int] = [:]
                for node in nodes {
                    let index = indexes[node.parent, default: 0]
                    indexes[node.parent] = index + 1
                    // A stable key per node: a copy interrupted at relaunch replays, never duplicates.
                    try await Self.perform(.create(node, index: index), profile: profile, mutationID: "migrate-file-" + node.id,
                                           on: connection)
                }
            }
            try await file.remove()
            fileTrees = [:]
            logger.info("bookmarks moved into the home daemon")
        } catch {
            logger.error("copy bookmarks to the daemon: \(String(describing: error), privacy: .public)")
        }
    }
}
