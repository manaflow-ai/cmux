import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileToast
import SwiftUI

/// Single owner of the "Reconnected to your Mac." toast.
///
/// Mounted exactly once, from the always-mounted workspace shell root, never
/// from tab or navigation content: tab contents remount as the user switches
/// primary tabs, and SwiftUI re-fires `onChange(initial: true)` on every
/// remount, so a presenter mounted inside a tab re-toasts "Reconnected" on
/// plain tab switches while connected. The gate additionally requires a
/// genuine disconnected → connected transport edge, so even a remount of
/// this modifier can never fabricate a reconnect.
struct MobileReconnectedToastPresenter: ViewModifier {
    let connectionState: MobileConnectionState
    @Environment(ToastCenter.self) private var toasts
    @State private var gate = MobileReconnectedToastGate()

    func body(content: Content) -> some View {
        content
            // `initial: true` primes the gate when the shell mounts already
            // connected (the initial call delivers previous == current, which
            // the gate never treats as a transition), so the first genuine
            // reconnect after mount still toasts.
            .onChange(of: connectionState, initial: true) { previous, current in
                guard gate.shouldToast(from: previous, to: current) else { return }
                toasts.present(.success(
                    L10n.string(
                        "mobile.connection.reconnectedToast",
                        defaultValue: "Reconnected to your Mac."
                    ),
                    coalescingKey: "connection.reconnected"
                ))
            }
    }
}

extension View {
    /// Mount once from the always-mounted workspace shell root.
    func reconnectedToastPresenter(
        connectionState: MobileConnectionState
    ) -> some View {
        modifier(MobileReconnectedToastPresenter(connectionState: connectionState))
    }
}
