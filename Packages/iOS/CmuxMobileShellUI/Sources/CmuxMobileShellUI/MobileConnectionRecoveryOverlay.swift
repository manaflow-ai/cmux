import CmuxMobileShell
import SwiftUI

private struct MobileConnectionRecoveryOverlay: ViewModifier {
    @Bindable var store: CMUXMobileShellStore
    var signOut: (() -> Void)?
    var isEnabled: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if isEnabled {
                MobileConnectionRecoveryBanner(
                    connectionRequiresReauth: store.connectionRequiresReauth,
                    connectionRecoveryFailed: store.connectionRecoveryFailed,
                    isRecoveringConnection: store.isRecoveringConnection,
                    connectionError: store.connectionError,
                    retry: { store.retryMobileConnection() },
                    signOut: signOut
                )
            }
        }
    }
}

extension View {
    func mobileConnectionRecoveryOverlay(
        store: CMUXMobileShellStore,
        signOut: (() -> Void)?,
        isEnabled: Bool = true
    ) -> some View {
        modifier(MobileConnectionRecoveryOverlay(
            store: store,
            signOut: signOut,
            isEnabled: isEnabled
        ))
    }
}
