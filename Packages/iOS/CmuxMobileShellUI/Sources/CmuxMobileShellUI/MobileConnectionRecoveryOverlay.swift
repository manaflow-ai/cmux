import CmuxMobileShell
import SwiftUI

private struct MobileConnectionRecoveryOverlay: ViewModifier {
    @Bindable var store: CMUXMobileShellStore
    var signOut: (@MainActor @Sendable () -> Void)?

    func body(content: Content) -> some View {
        // Reauth is a blocking condition, not a status: the Mac rejected the
        // connection, so a durable banner with Sign Out is the only honest
        // surface. Transient reconnects and failed attempts keep the terminal
        // visible and ride the status pill / picker status line instead.
        content.overlay(alignment: .top) {
            if store.connectionRequiresReauth {
                MobileConnectionRecoveryBanner(
                    connectionRequiresReauth: store.connectionRequiresReauth,
                    connectionError: store.connectionError,
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
