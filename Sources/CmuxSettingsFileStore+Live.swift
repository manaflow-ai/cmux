import CmuxSettings
import Foundation

extension CmuxSettingsFileStore {
    /// Returns the effective socket access policy represented by live defaults.
    static func liveSocketAccessMode(defaults: UserDefaults = .standard) -> SocketControlMode {
        let raw = defaults.string(forKey: SocketControlSettings.appStorageKey)
            ?? SocketControlSettings.defaultMode.rawValue
        return SocketControlSettings.effectiveMode(userMode: SocketControlSettings.migrateMode(raw))
    }

    /// Creates the process store wired to the host's shared reload coordinator.
    static var appLive: CmuxSettingsFileStore {
        CmuxSettingsFileStore(
            onWatchedFileReload: { source in
                AppDelegate.shared?.reconcileSocketListenerConfiguration(source: source)
            }
        )
    }
}
