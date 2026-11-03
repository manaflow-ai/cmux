import CmuxNextCloudTunnel
import CmuxNextCompat
import CmuxNextSettings
import Foundation

/// Applies `cloud.tunnel.enabled` to the Cloud Tunnel: the launch value through
/// ``CloudTunnelController/restore(enabled:)`` (off touches nothing; on never asks for approval),
/// and every later change through ``CloudTunnelController/enable()`` or
/// ``CloudTunnelController/disable()``. Settings, `cmux cloud tunnel on|off` and MCP all change the
/// setting, so this is the one path to the controller.
final class CloudTunnelSettingSync {
    private var observation: Task<Void, Never>?

    func start(settings: SettingsController, tunnel: CloudTunnelController) {
        observation?.cancel()
        // task-owner: the app's lifetime; one observation of the one setting.
        observation = Task {
            var applied: Bool?
            for await enabled in ObservationStream({ CloudTunnelSetting().enabled(in: settings.snapshot.root) }) {
                guard enabled != applied else { continue }
                if applied == nil {
                    await tunnel.restore(enabled: enabled)
                } else if enabled {
                    await tunnel.enable()
                } else {
                    await tunnel.disable()
                }
                applied = enabled
            }
        }
    }
}
