import CmuxMobileShell
import CmuxMobileToast
import SwiftUI

private struct MobileConnectionRecoveryOverlay: ViewModifier {
    @Bindable var store: CMUXMobileShellStore
    var signOut: (@MainActor @Sendable () -> Void)?
    @Environment(ToastCenter.self) private var toasts

    @ViewBuilder
    func body(content: Content) -> some View {
        if toasts.isEnabled {
            // Transient statuses ride the toast capsule, owned solely by
            // ConnectionStatusToastPresenter in the always-mounted shell.
            // Reauth and failed recovery are blocking conditions, not
            // statuses: a toast can be swiped away with nothing left to
            // re-present it, so their Sign Out / Retry actions keep the
            // durable banner.
            content.overlay(alignment: .top) {
                if store.connectionRequiresReauth || store.connectionRecoveryFailed {
                    MobileConnectionRecoveryBanner(
                        connectionRequiresReauth: store.connectionRequiresReauth,
                        connectionRecoveryFailed: store.connectionRecoveryFailed,
                        isRecoveringConnection: false,
                        connectionError: store.connectionError,
                        retry: { store.retryMobileConnection() },
                        signOut: signOut
                    )
                }
            }
        } else {
            content.overlay(alignment: .top) {
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
        signOut: (@MainActor @Sendable () -> Void)?
    ) -> some View {
        modifier(MobileConnectionRecoveryOverlay(store: store, signOut: signOut))
    }
}
