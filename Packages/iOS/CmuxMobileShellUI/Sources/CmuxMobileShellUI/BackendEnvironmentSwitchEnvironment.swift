#if os(iOS)
public import CMUXAuthCore
import SwiftUI

private struct BackendEnvironmentSwitchEnvironmentKey: EnvironmentKey {
    static let defaultValue: CMUXBackendEnvironmentSwitchState? = nil
}

extension EnvironmentValues {
    /// The composition root's runtime backend-environment switch state (the
    /// resolved SELECTION — lane or explicit choice — and the build's own
    /// lane). `nil` in previews and hosts without the app root, which hide
    /// the Settings backend section entirely.
    public var backendEnvironmentSwitch: CMUXBackendEnvironmentSwitchState? {
        get { self[BackendEnvironmentSwitchEnvironmentKey.self] }
        set { self[BackendEnvironmentSwitchEnvironmentKey.self] = newValue }
    }
}
#endif
