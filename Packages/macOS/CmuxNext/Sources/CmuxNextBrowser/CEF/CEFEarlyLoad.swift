import Foundation
import os

/// A framework load begun from any thread before a page asked for Chromium (`CEFEngine.beginEarlyLoad`):
/// the shim and the framework are mapped on a background task, and the runtime's first
/// ``CEFRuntime/start(layout:environment:trigger:)`` or ``CEFRuntime/preload(layout:)`` for the same layout takes that
/// task instead of loading again. Only the load moves earlier; `CefInitialize` still runs on the main thread when a page
/// (or the warm start) asks.
nonisolated final class CEFEarlyLoad: Sendable {
    typealias LoadTask = Task<Result<CEFLoadedLibrary, CEFRuntime.BootError>, Never>

    private struct Begun: Sendable {
        var layout: CEFRuntimeLayout
        var task: LoadTask
    }

    private let begun = OSAllocatedUnfairLock<Begun?>(initialState: nil)
    private let loader: CEFRuntime.LibraryLoader

    init(loader: @escaping CEFRuntime.LibraryLoader) {
        self.loader = loader
    }

    /// Starts the load of `layout` on a background task, once: a later call returns the first call's task.
    @discardableResult
    func begin(_ layout: CEFRuntimeLayout) -> LoadTask {
        begun.withLock { begun in
            if let begun { return begun.task }
            let loader = loader
            let task: LoadTask = Task.detached(priority: .userInitiated) { loader(layout) }
            begun = Begun(layout: layout, task: task)
            return task
        }
    }

    /// The begun load of `layout`, nil when none began or it began for another layout (the runtime then loads its own).
    func task(for layout: CEFRuntimeLayout?) -> LoadTask? {
        guard let layout else { return nil }
        return begun.withLock { $0?.layout == layout ? $0?.task : nil }
    }
}
