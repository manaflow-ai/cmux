import CmuxMobileShell
import SwiftUI

extension CMUXMobileRootView {
    var shouldShowDeleteComputersVerifier: Bool {
        #if os(iOS) && DEBUG
        return MobileDeleteComputersVerifier().isEnabled
        #else
        return false
        #endif
    }

    @ViewBuilder var deleteComputersVerifier: some View {
        #if os(iOS) && DEBUG
        DeleteComputersVerifierView()
        #else
        EmptyView()
        #endif
    }
}
