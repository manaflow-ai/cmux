import SwiftUI

/// Carries the app's single ``TailscaleStatusObserving`` detector down the
/// SwiftUI view tree so connection-adjacent surfaces (pairing, the
/// disconnected shell, onboarding/setup help) can explain "your tailnet is
/// off" instead of letting failures look like mysterious hangs.
///
/// The app composition root builds one detector and the root scene injects it
/// with ``SwiftUICore/View/tailscaleStatusMonitor(_:)``; views read it via
/// `@Environment(\.tailscaleStatusMonitor)`. The default is `nil`, meaning
/// "no detector wired": previews and unwired subtrees show no Tailscale
/// guidance rather than guessing.
private struct TailscaleStatusMonitorKey: EnvironmentKey {
    static let defaultValue: (any TailscaleStatusObserving)? = nil
}

extension EnvironmentValues {
    /// The tailnet-status detector for the current view subtree, if wired.
    public var tailscaleStatusMonitor: (any TailscaleStatusObserving)? {
        get { self[TailscaleStatusMonitorKey.self] }
        set { self[TailscaleStatusMonitorKey.self] = newValue }
    }
}

extension View {
    /// Injects the tailnet-status detector into this view subtree.
    /// - Parameter monitor: The detector to inject.
    /// - Returns: A view whose descendants read `@Environment(\.tailscaleStatusMonitor)`.
    public func tailscaleStatusMonitor(_ monitor: (any TailscaleStatusObserving)?) -> some View {
        environment(\.tailscaleStatusMonitor, monitor)
    }
}
