import Foundation

/// Owns cancellable sidebar work without imposing an executor on ARC teardown.
final class ArtifactSidebarTaskBag {
    private var watcher: Task<Void, Never>?
    private var search: Task<Void, Never>?
    private var action: Task<Void, Never>?

    deinit {
        cancelAll()
    }

    @MainActor
    func replaceWatcher(with makeTask: () -> Task<Void, Never>) {
        watcher?.cancel()
        watcher = makeTask()
    }

    @MainActor
    func replaceSearch(with makeTask: () -> Task<Void, Never>) {
        search?.cancel()
        search = makeTask()
    }

    @MainActor
    func replaceAction(with makeTask: () -> Task<Void, Never>) {
        action?.cancel()
        action = makeTask()
    }

    @MainActor
    func cancelSearch() {
        search?.cancel()
        search = nil
    }

    func cancelAll() {
        watcher?.cancel()
        watcher = nil
        search?.cancel()
        search = nil
        action?.cancel()
        action = nil
    }
}
