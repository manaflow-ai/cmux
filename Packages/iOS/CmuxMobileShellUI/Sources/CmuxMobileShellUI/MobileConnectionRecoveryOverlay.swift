import CmuxMobileShell
import SwiftUI

private struct MobileConnectionRecoveryOverlay: ViewModifier {
    @Bindable var store: CMUXMobileShellStore
    var signOut: (@MainActor @Sendable () -> Void)?
    var isActive = true

    func body(content: Content) -> some View {
        // Reauth is a blocking condition, not a status: the Mac rejected the
        // connection, so a durable banner with Sign Out is the only honest
        // surface. Transient reconnects and failed attempts keep the terminal
        // visible and ride the status pill / picker status line instead.
        content.overlay(alignment: .top) {
            if isActive, store.connectionRequiresReauth {
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
    /// - Parameter isActive: Whether this attachment point is the visible
    ///   layer. The workspace detail attaches the overlay to both its base
    ///   layer and the terminal's full-screen cover; only the visible layer
    ///   renders the banner so it never draws twice.
    func mobileConnectionRecoveryOverlay(
        store: CMUXMobileShellStore,
        signOut: (@MainActor @Sendable () -> Void)?,
        isActive: Bool = true
    ) -> some View {
        modifier(
            MobileConnectionRecoveryOverlay(
                store: store,
                signOut: signOut,
                isActive: isActive
            )
        )
    }
}
