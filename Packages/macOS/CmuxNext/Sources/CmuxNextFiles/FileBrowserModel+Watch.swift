import CmuxNextWakeups
import Foundation

/// Live changes and re-sorts, on Chrome's reply model (`PostTaskAndReplyWithResult`, base/task/thread_pool.h): the
/// work runs off main and its result lands on the model as one posted task with a class.
///
/// - A watched change reads the rows it starts from in one visible task, lists the changed names (or the whole
///   folder on a rescan) off main, and lands the new rows in another visible task: the pane shows them, and no action
///   of the person caused them.
/// - A re-sort (a new ``FileBrowserModel/sortOrder``) sorts off main and lands as one userBlocking task: the rest of
///   the person's click on a column.
///
/// A result whose folder or listing is gone by then (``FileBrowserModel/generation``) applies nothing.
extension FileBrowserModel {
    /// The rows a watched change starts from.
    struct WatchBase: Sendable {
        let rows: [FileEntry]
        let order: FileSortOrder
        /// The listing the rows belong to.
        let generation: Int
    }

    /// What a watched change makes of the rows: the new rows in order, or the folder's failure message.
    enum WatchedRows: Sendable, Equatable {
        case rows([FileEntry])
        case failed(String)
    }

    /// Follows `target`'s changes until the next folder or ``stop()``.
    func startWatching(_ target: URL) {
        watchTask?.cancel()
        let stream = watcher.changes(in: target)
        let work = self.work, lister = self.lister
        // task-owner: stored in watchTask; the next folder and stop() cancel it
        watchTask = Task { @concurrent [weak self] in
            for await change in stream {
                guard self != nil else { return }
                let base = await work.apply(.visible, owner: "Files.watch.read") { [weak self] () -> WatchBase? in
                    self?.watchBase(in: target)
                }
                guard let base else { return }
                let rows = await FileBrowserModel.rows(after: change, from: base, in: target, lister: lister)
                guard !Task.isCancelled else { return }
                work.postFromAnyThread(.visible, owner: "Files.watch.apply") { [weak self] in self?.land(rows, from: base, in: target) }
            }
        }
    }

    /// Applies one watched change (single rows, or a full listing on rescan): the watch's three steps in one call.
    func apply(_ change: FolderChange, in target: URL) async {
        guard let base = watchBase(in: target) else { return }
        land(await Self.rows(after: change, from: base, in: target, lister: lister), from: base, in: target)
    }

    /// Sorts ``all`` again in the current order, off main.
    func resort() {
        let order = sortOrder, snapshot = all, token = generation, work = self.work
        // task-owner: one sort; a newer listing makes its result stale (token)
        Task { @concurrent [weak self] in
            let sorted = order.sorted(snapshot)
            guard self != nil else { return }
            work.postFromAnyThread(.userBlocking, owner: "Files.resort") { [weak self] in self?.landSorted(sorted, order: order, token: token) }
        }
    }

    // MARK: Internals

    private func watchBase(in target: URL) -> WatchBase? {
        guard target == folder else { return nil }
        return WatchBase(rows: all, order: sortOrder, generation: generation)
    }

    /// The rows after `change`: the changed names read again over `base`, or the whole folder listed again on a
    /// rescan or a burst of more than 500 names.
    @concurrent
    private static func rows(after change: FolderChange, from base: WatchBase, in folder: URL,
                             lister: any DirectoryListing) async -> WatchedRows {
        guard case .items(let names) = change, names.count <= 500 else {
            do {
                return .rows(try await listSorted(folder, lister: lister, order: base.order))
            } catch let error as FileBrowserError {
                return .failed(describe(error))
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        var byName = Dictionary(base.rows.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for name in Set(names) {
            let url = folder.appendingPathComponent(name)
            if let entry = await lister.entry(at: url) {
                byName[name] = FileEntry(name: name, in: folder, kind: entry.kind, size: entry.size, modified: entry.modified,
                                        created: entry.created, isHidden: entry.isHidden)
            } else {
                byName[name] = nil
            }
        }
        return .rows(base.order.sorted(Array(byName.values)))
    }

    private func land(_ rows: WatchedRows, from base: WatchBase, in target: URL) {
        guard target == folder, base.generation == generation else { return }
        switch rows {
        case .rows(let rows):
            all = rows
            if case .failed = phase { phase = .ready }
            // The order changed while the rows were read: sort them again before they show.
            if base.order == sortOrder { refilter() } else { resort() }
        case .failed(let message):
            phase = .failed(message)
        }
    }

    private func landSorted(_ sorted: [FileEntry], order: FileSortOrder, token: Int) {
        guard token == generation, order == sortOrder else { return }
        all = sorted
        refilter()
    }
}
