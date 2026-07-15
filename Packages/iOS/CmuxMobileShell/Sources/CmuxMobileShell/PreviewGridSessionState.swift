import Foundation

/// Reference-backed preview state kept out of the zero-growth composite file.
@MainActor
final class PreviewGridSessionState {
    let browserPreview = BrowserPreviewSessionState()
    let store = PreviewGridStore(
        maximumUpdatesPerSecond: MobileShellComposite.defaultPreviewGridUpdatesPerSecond
    )
    var demandRevision: UInt64 = 0
    var demandRefreshTask: Task<Void, Never>?
    var baselineTasksBySurfaceID: [String: Task<Void, Never>] = [:]

    func cancelConnectionTasks() {
        demandRefreshTask?.cancel()
        demandRefreshTask = nil
        for task in baselineTasksBySurfaceID.values {
            task.cancel()
        }
        baselineTasksBySurfaceID.removeAll()
    }
}
