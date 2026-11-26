import Foundation

extension AgentHibernationController {
    @MainActor
    final class PostTeardownRestoreCancellationState {
        var restoresSnapshotOnCancellation = true
    }
}
