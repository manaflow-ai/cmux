@testable import CmuxBrowser

actor CancellationObservingPageMetadataResolver: BrowserPageMetadataResolving {
    private var continuation: CheckedContinuation<[BrowserPageMetadataResolvedAddress], Never>?
    private var cancellationObserved = false

    func addresses(for host: String) async -> [BrowserPageMetadataResolvedAddress] {
        _ = host
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled {
                    cancelQuery()
                }
            }
        } onCancel: {
            Task { await self.cancelQuery() }
        }
    }

    func didObserveCancellation() -> Bool {
        cancellationObserved
    }

    private func cancelQuery() {
        cancellationObserved = true
        continuation?.resume(returning: [])
        continuation = nil
    }
}
