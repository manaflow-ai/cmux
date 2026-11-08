import Foundation

extension WorkspaceTerminalFontSizeCoordinator {
    final class TransferRequestRecord {
        let request: PendingRequest
        let configuredRuntimePoints: Float32
        let magnificationPercent: Int
        weak var previous: TransferRequestRecord?
        var next: TransferRequestRecord?
        // Endpoint indexes keep request retirement proportional to the
        // obligations that actually touch this record.
        var obligationStartPanelIds: Set<UUID> = []
        var obligationEndPanelIds: Set<UUID> = []
        var stagedIntervalStartCount = 0
        var stagedIntervalEndCount = 0

        init(
            request: PendingRequest,
            configuredRuntimePoints: Float32,
            magnificationPercent: Int
        ) {
            self.request = request
            self.configuredRuntimePoints = configuredRuntimePoints
            self.magnificationPercent = magnificationPercent
        }
    }
}
