#if canImport(UIKit) && DEBUG
import CmuxMobileShell
import SwiftUI

struct MobileTerminalDiagnosticsOverlay: UIViewRepresentable {
    let surfaceID: String
    let store: CMUXMobileShellStore

    func makeUIView(context: Context) -> MobileTerminalDiagnosticsOverlayView {
        MobileTerminalDiagnosticsOverlayView(surfaceID: surfaceID, store: store)
    }

    func updateUIView(_ uiView: MobileTerminalDiagnosticsOverlayView, context: Context) {
        uiView.surfaceID = surfaceID
        uiView.store = store
    }
}
#endif
