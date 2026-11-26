import CmuxSettingsUI
import Foundation

extension HostSettingsActions {
    func notificationSoundAgentOptions() async -> [NotificationSoundAgentOption] {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        return await NotificationSoundAgentRegistryLoader().load(
            homeDirectory: homeDirectory
        )
    }

    func validateNotificationSoundFile(path: String) async -> Bool {
        await NotificationSoundSettings.validateCustomSoundFileForSelection(path: path)
    }
}
