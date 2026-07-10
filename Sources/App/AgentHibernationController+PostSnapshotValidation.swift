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
        if let inFlight = postSnapshotValidationIndexTask {
            if inFlight.startSequence >= minimumStartSequence {
                return inFlight.task
            }
            predecessor = inFlight.task
        } else {
            predecessor = nil
        }
        let requestID = UUID()
        let startSequence = postSnapshotValidationIndexSequence
        let task = Task.detached(priority: .utility) { () -> RestorableAgentSessionIndex in
            _ = await predecessor?.value
            guard !Task.isCancelled else { return .empty }
            return await loader()
        }
        postSnapshotValidationIndexTask = PostSnapshotValidationIndexTask(
            requestID: requestID,
            startSequence: startSequence,
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
