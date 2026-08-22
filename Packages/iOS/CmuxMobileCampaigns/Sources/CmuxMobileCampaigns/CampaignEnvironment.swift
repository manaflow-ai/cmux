public import SwiftUI

/// Defaults to enabled so previews and isolated package hosts render
/// campaigns without extra setup; the app root injects the live PostHog
/// kill-switch value.
private struct CampaignsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether remote in-app campaigns may render any surface.
    public var campaignsEnabled: Bool {
        get { self[CampaignsEnabledKey.self] }
        set { self[CampaignsEnabledKey.self] = newValue }
    }
}

extension View {
    /// Applies the remotely controlled campaign kill switch.
    public func campaignsEnabled(_ isEnabled: Bool) -> some View {
        environment(\.campaignsEnabled, isEnabled)
    }
}
