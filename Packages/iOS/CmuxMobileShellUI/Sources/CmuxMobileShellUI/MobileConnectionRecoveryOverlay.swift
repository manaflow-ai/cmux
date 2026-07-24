import CmuxMobileShell
import CmuxMobileToast
import SwiftUI

private struct MobileConnectionRecoveryOverlay: ViewModifier {
    @Bindable var store: CMUXMobileShellStore
    var signOut: (@MainActor @Sendable () -> Void)?
    @Environment(ToastCenter.self) private var toasts

    @ViewBuilder
    func body(content: Content) -> some View {
        let phase = ConnectionRecoveryToastPhase.derive(
            requiresReauth: store.connectionRequiresReauth,
            recoveryFailed: store.connectionRecoveryFailed,
            isRecovering: store.isRecoveringConnection,
            connectionError: store.connectionError
        )

        if toasts.isEnabled {
            content.onChange(of: phase, initial: true) { previousPhase, phase in
                switch phase {
                case .reauth(let message):
                    toasts.present(.connectionReauthRequired(message: message, signOut: signOut))
                case .lost:
                    toasts.present(.connectionLost {
                        store.retryMobileConnection()
                    })
                case .recovering:
                    toasts.present(.connectionReconnecting())
                case .idle:
                    if case .reauth = previousPhase {
                        toasts.dismiss(coalescingKey: Toast.connectionStatusKey)
                    }
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
