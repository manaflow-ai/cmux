import CmuxCore

/// One connection-state publication observed by ``ReadinessRecordingHost``.
struct ReadinessConnectionPublication: Equatable, Sendable {
    let state: WorkspaceRemoteConnectionState
    let detail: String?
}
