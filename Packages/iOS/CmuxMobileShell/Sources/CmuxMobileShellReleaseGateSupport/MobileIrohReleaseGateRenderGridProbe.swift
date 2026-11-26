#if DEBUG
import CMUXMobileCore
import CmuxMobileRPC
import Foundation

struct MobileIrohReleaseGateRenderGridProbe: Sendable {
    private let surfaceID: String
    private let marker: String

    init(surfaceID: String, marker: String) {
        self.surfaceID = surfaceID
        self.marker = marker
    }

    func consume(_ event: MobileEventEnvelope) -> Bool {
        guard event.topic == "terminal.render_grid",
              let payload = event.payloadJSON else {
            return false
        }
        let wrapped = try? MobileTerminalRenderGridEvent.decode(payload)
        guard let frame = wrapped?.frame
                ?? (try? JSONDecoder().decode(MobileTerminalRenderGridFrame.self, from: payload)),
              frame.surfaceID == surfaceID else {
            return false
        }
        return frame.plainRows().joined().contains(marker)
    }
}
#endif
