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
        guard let frame = event.renderGrid, frame.surfaceID == surfaceID else {
            return false
        }
        return frame.plainRows().joined().contains(marker)
    }
}
#endif
