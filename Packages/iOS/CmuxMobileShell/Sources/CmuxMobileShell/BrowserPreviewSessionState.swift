import Foundation

/// Reference-backed browser preview state kept outside the zero-growth composite.
@MainActor
final class BrowserPreviewSessionState {
    let store = BrowserPreviewStore()
    var demandRevision: UInt64 = 0
    var demandRefreshTask: Task<Void, Never>?

    func cancelConnectionTasks() {
        demandRefreshTask?.cancel()
        demandRefreshTask = nil
    }
}
