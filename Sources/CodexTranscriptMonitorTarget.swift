import Foundation

/// The current live destination for one transcript monitor's notifications.
nonisolated struct CodexTranscriptMonitorTarget: Sendable, Equatable {
    let workspaceID: UUID
    let surfaceID: UUID?
}
