import CmuxMobileTransport
import SwiftUI

/// Carries the app's single ``CmuxMobileTransport/TailscaleStatusMonitor``
/// down the SwiftUI view tree so connection-adjacent surfaces (pairing, the
/// disconnected shell, onboarding/setup help) can explain "your tailnet is
/// off" instead of letting failures look like mysterious hangs.
///
/// The root view injects one monitor with ``SwiftUICore/View/tailscaleStatusMonitor(_:)``;
/// views read it via `@Environment(\.tailscaleStatusMonitor)`. The default is
/// `nil`, meaning "no detector wired": previews and unwired subtrees show no
/// Tailscale guidance rather than guessing.
private struct TailscaleStatusMonitorKey: EnvironmentKey {
    static let defaultValue: TailscaleStatusMonitor? = nil
}

extension EnvironmentValues {
    /// The tailnet-status monitor for the current view subtree, if wired.
    public var tailscaleStatusMonitor: TailscaleStatusMonitor? {
        get { self[TailscaleStatusMonitorKey.self] }
        set { self[TailscaleStatusMonitorKey.self] = newValue }
    }
}

extension View {
    /// Injects the tailnet-status monitor into this view subtree.
    /// - Parameter monitor: The monitor to inject.
    /// - Returns: A view whose descendants read `@Environment(\.tailscaleStatusMonitor)`.
    public func tailscaleStatusMonitor(_ monitor: TailscaleStatusMonitor?) -> some View {
        environment(\.tailscaleStatusMonitor, monitor)
    }
}
