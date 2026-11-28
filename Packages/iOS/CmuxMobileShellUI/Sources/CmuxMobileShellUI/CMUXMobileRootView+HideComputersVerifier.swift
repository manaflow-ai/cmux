import CmuxMobileShell
import SwiftUI

extension CMUXMobileRootView {
    var shouldShowHideComputersVerifier: Bool {
        #if os(iOS) && DEBUG
        return MobileHideComputersVerifier().isEnabled
        #else
        return false
        #endif
    }

    @ViewBuilder var hideComputersVerifier: some View {
        #if os(iOS) && DEBUG
        HideComputersVerifierView()
        #else
        EmptyView()
        #endif
    }
}
