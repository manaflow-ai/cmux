public import Foundation
import CmuxSettings

/// Derives whether remote listening-port discovery may run from the global
/// sidebar ports-visibility settings.
///
/// Mirrors the sidebar's own precedence (`sidebar.hideAllDetails` wins over
/// `sidebar.showPorts`, see `SidebarWorkspaceAuxiliaryDetailVisibility.resolved`):
/// when the ports detail is not displayed there is nothing for the remote scans
/// to populate, so the backend ssh port-scan loop is suspended (issue #6123).
///
/// Lifted from `Workspace.remotePortScanningEnabledFromSettings(defaults:)`,
/// kept a stateless value type per the no-namespace-enums convention. The
/// result feeds ``RemoteSessionCoordinator/updateRemotePortScanningEnabled(_:)``.
public struct RemotePortScanningPolicy: Sendable {
    /// Creates the policy.
    public init() {}

    /// Whether the backend remote port-scan loop should run, read from the
    /// sidebar ports-visibility defaults.
    public func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = SettingCatalog()
        let showsPorts = settings.value(for: catalog.sidebar.showPorts)
        let hidesAllDetails = settings.value(for: catalog.sidebar.hideAllDetails)
        return showsPorts && !hidesAllDetails
    }
}
