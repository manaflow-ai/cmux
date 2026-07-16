import Foundation

nonisolated struct PullRequestPanelObservationID: Hashable, Sendable {
    let workspaceID: UUID
    let isVisible: Bool
}
