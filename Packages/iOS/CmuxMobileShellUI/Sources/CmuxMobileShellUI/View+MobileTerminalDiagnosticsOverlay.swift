import CmuxMobileShell
import SwiftUI

extension View {
    @ViewBuilder
    func mobileTerminalDiagnosticsOverlay(
        surfaceID: String,
        store: CMUXMobileShellStore
    ) -> some View {
        #if canImport(UIKit) && DEBUG
        ignoresSafeArea(.keyboard, edges: .bottom)
            .overlay {
                MobileTerminalDiagnosticsOverlay(surfaceID: surfaceID, store: store)
            }
        #else
        ignoresSafeArea(.keyboard, edges: .bottom)
        #endif
    }
}
