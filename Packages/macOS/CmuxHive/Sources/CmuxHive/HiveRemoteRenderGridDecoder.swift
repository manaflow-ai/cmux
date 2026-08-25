import CMUXMobileCore
import CmuxMobileRPC
import Foundation

/// Decodes the two wire shapes used by remote render-grid events and replay.
struct HiveRemoteRenderGridDecoder: Sendable {
    /// Decode a wrapped or bare render-grid event.
    func decodeFrame(_ payload: Data) -> MobileTerminalRenderGridFrame? {
        let decoder = JSONDecoder()
        if let event = try? decoder.decode(MobileTerminalRenderGridEvent.self, from: payload),
           let frame = event.frame {
            return frame
        }
        return try? decoder.decode(MobileTerminalRenderGridFrame.self, from: payload)
    }

    /// Decode one terminal replay response.
    func decodeReplay(_ payload: Data) throws -> MobileTerminalReplayResponse {
        try JSONDecoder().decode(MobileTerminalReplayResponse.self, from: payload)
    }
}
