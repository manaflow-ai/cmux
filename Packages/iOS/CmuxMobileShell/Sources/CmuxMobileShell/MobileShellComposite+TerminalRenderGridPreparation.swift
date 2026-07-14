import Foundation

extension MobileShellComposite {
    func beginTerminalRenderGridEventPreparation(surfaceID: String) -> UUID {
        let token = UUID()
        terminalRenderGridEventPreparationTokensBySurfaceID[surfaceID, default: []].insert(token)
        return token
    }

    func finishTerminalRenderGridEventPreparation(surfaceID: String, token: UUID) {
        guard var tokens = terminalRenderGridEventPreparationTokensBySurfaceID[surfaceID],
              tokens.remove(token) != nil else {
            return
        }
        guard tokens.isEmpty else {
            terminalRenderGridEventPreparationTokensBySurfaceID[surfaceID] = tokens
            return
        }
        terminalRenderGridEventPreparationTokensBySurfaceID.removeValue(forKey: surfaceID)
        guard let streamToken = terminalReplayBarrierPendingPreparationAckTokensBySurfaceID
            .removeValue(forKey: surfaceID) else {
            return
        }
        terminalOutputDidProcess(surfaceID: surfaceID, streamToken: streamToken)
    }
}
