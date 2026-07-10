import Foundation

extension AgentHibernationController {
    func markPostSnapshotValidationPoint() -> UInt64 {
        postSnapshotValidationIndexSequence = postSnapshotValidationIndexSequence &+ 1
        return postSnapshotValidationIndexSequence
    }

    /// Serializes validation boundaries within the controller before invoking
    /// the caller's post-boundary loader.
    func sharedPostSnapshotValidationIndexTask(
        minimumStartSequence: UInt64,
        loader: @escaping @Sendable () async -> RestorableAgentSessionIndex
    ) -> Task<RestorableAgentSessionIndex, Never> {
        let predecessor: Task<RestorableAgentSessionIndex, Never>?
        if var inFlight = postSnapshotValidationIndexTask {
            if inFlight.startSequence >= minimumStartSequence {
                return inFlight.task
            }
            if !inFlight.hasStartedCapture {
                inFlight.startSequence = minimumStartSequence
                postSnapshotValidationIndexTask = inFlight
                return inFlight.task
            }
            predecessor = inFlight.task
        } else {
            predecessor = nil
        }
        let requestID = UUID()
        let startSequence = postSnapshotValidationIndexSequence
        let task = Task.detached(priority: .utility) { [weak self] () -> RestorableAgentSessionIndex in
            _ = await predecessor?.value
            guard !Task.isCancelled else { return .empty }
            let shouldCapture = await MainActor.run {
                guard let self,
                      var inFlight = self.postSnapshotValidationIndexTask,
                      inFlight.requestID == requestID else {
                    return false
                }
                inFlight.hasStartedCapture = true
                self.postSnapshotValidationIndexTask = inFlight
                return true
            }
            guard shouldCapture, !Task.isCancelled else { return .empty }
            return await loader()
        }
        postSnapshotValidationIndexTask = PostSnapshotValidationIndexTask(
            requestID: requestID,
            startSequence: startSequence,
            hasStartedCapture: false,
            task: task
        )
        Task { @MainActor in
            _ = await task.value
            guard self.postSnapshotValidationIndexTask?.requestID == requestID else { return }
            self.postSnapshotValidationIndexTask = nil
        }
        return task
    }
}
