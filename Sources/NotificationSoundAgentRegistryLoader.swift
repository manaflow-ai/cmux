import CmuxSettingsUI
import CmuxSettings
import Foundation

/// Loads the agent rows used by the notification-sound matrix.
///
/// Vault registry discovery performs synchronous filesystem reads.  Keeping
/// that work on this actor prevents a Settings render, which is main-actor
/// isolated, from blocking while the registry is decoded.
actor NotificationSoundAgentRegistryLoader {
    func load(homeDirectory: String) -> [NotificationSoundAgentOption] {
        var optionsByID: [String: NotificationSoundAgentOption] = [:]
        for definition in CmuxTaskManagerCodingAgentDefinition.builtIns {
            guard NotificationSoundOverrideContext.isValidAgentID(definition.id) else {
                continue
            }
            optionsByID[definition.id] = NotificationSoundAgentOption(
                id: definition.id,
                displayName: definition.displayName
            )
        }

        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory)
        for registration in registry.registrations {
            guard NotificationSoundOverrideContext.isValidAgentID(registration.id) else {
                continue
            }
            optionsByID[registration.id] = NotificationSoundAgentOption(
                id: registration.id,
                displayName: registration.name
            )
        }
        return optionsByID.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}
