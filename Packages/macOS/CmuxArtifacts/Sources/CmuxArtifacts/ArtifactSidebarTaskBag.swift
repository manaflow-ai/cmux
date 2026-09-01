import Foundation

/// Owns cancellable sidebar work without imposing an executor on ARC teardown.
final class ArtifactSidebarTaskBag {
    private var watchers: [Task<Void, Never>] = []
    private var search: Task<Void, Never>?
    private var action: Task<Void, Never>?

    deinit {
        cancelAll()
    }

    @MainActor
    func replaceWatcher(with makeTasks: () -> [Task<Void, Never>]) {
        watchers.forEach { $0.cancel() }
        watchers = makeTasks()
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
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        search?.cancel()
        search = nil
        action?.cancel()
        action = nil
    }
}
