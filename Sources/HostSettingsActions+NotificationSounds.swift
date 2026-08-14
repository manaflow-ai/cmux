import CmuxSettingsUI
import Foundation

extension HostSettingsActions {
    func notificationSoundAgentOptions() -> [NotificationSoundAgentOption] {
        var optionsByID: [String: NotificationSoundAgentOption] = [:]
        for definition in CmuxTaskManagerCodingAgentDefinition.builtIns {
            optionsByID[definition.id] = NotificationSoundAgentOption(
                id: definition.id,
                displayName: definition.displayName
            )
        }
        let registry = CmuxVaultAgentRegistry.load(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
        for registration in registry.registrations {
            optionsByID[registration.id] = NotificationSoundAgentOption(
                id: registration.id,
                displayName: registration.name
            )
        }
        return optionsByID.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func validateNotificationSoundFile(path: String) async -> Bool {
        await NotificationSoundSettings.validateCustomSoundFileForSelection(path: path)
    }
}
