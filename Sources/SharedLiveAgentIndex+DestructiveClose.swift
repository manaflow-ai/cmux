import Foundation

extension SharedLiveAgentIndex {
    private static let destructiveCloseCaptureAttemptLimit = 2

    /// Captures agent metadata off-main for a committed destructive close.
    /// The caller receives a boundary for safe terminal teardown while the
    /// bounded generation continues slower filesystem enrichment.
    func indexRefreshTaskForDestructiveClose() -> DestructiveCloseIndexCapture {
        let teardownBoundary = SharedLiveAgentIndexProcessMetadataBoundary()
        let firstRequest = requestRefreshDetails(
            freshness: .captureAfterRequest,
            publication: .scoped,
            validating: nil
        )
        let indexTask = Task { @MainActor [self] () -> RestorableAgentSessionIndex? in
            // The returned operation owns its coordinator until the requested
            // generation resolves, including for injected non-singleton indexes.
            defer {
                teardownBoundary.resolve(captured: false)
                _ = self
            }
            var request = firstRequest
            for attempt in 0..<Self.destructiveCloseCaptureAttemptLimit {
                let captureObserver = Task { @MainActor in
                    if await request.processMetadataCapture.wait() {
                        teardownBoundary.resolve(captured: true)
                    }
                }
                let result = await request.task.value
                _ = await captureObserver.value
                if let index = result?.index {
                    return index
                }
                if attempt + 1 < Self.destructiveCloseCaptureAttemptLimit {
                    request = requestRefreshDetails(
                        freshness: .captureAfterRequest,
                        publication: .scoped,
                        validating: nil
                    )
                }
            }
            return nil
        }
        let processMetadataCaptureTask = Task {
            _ = await teardownBoundary.wait()
        }
        return DestructiveCloseIndexCapture(
            indexTask: indexTask,
            processMetadataCaptureTask: processMetadataCaptureTask
        )
    }
}
