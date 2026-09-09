import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// Decodes the two wire shapes used by remote render-grid events and replay.
actor HiveRemoteRenderGridDecoder {
    private let decoder = JSONDecoder()

    /// Decode a wrapped or bare render-grid event.
    func decodeFrame(_ payload: Data) -> MobileTerminalRenderGridFrame? {
        if let event = try? decoder.decode(MobileTerminalRenderGridEvent.self, from: payload),
           let frame = event.frame {
            return frame
        }
        return try? decoder.decode(MobileTerminalRenderGridFrame.self, from: payload)
    }

    /// Decode a replay only when the host's routing identity matches the requesting session.
    func decodeReplay(
        _ payload: Data, workspaceID: String, surfaceID: String
    ) throws -> MobileTerminalReplayResponse {
        let envelope = try decoder.decode(HiveRemoteReplayEnvelope.self, from: payload)
        guard envelope.workspaceID == workspaceID else {
            throw HiveRemoteTerminalSessionError.mismatchedWorkspace
        }
        guard envelope.surfaceID == surfaceID else {
            throw HiveRemoteTerminalSessionError.mismatchedSurface
        }
        return envelope.response
    }
}
