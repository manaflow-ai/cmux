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
        // Keep the eager Settings grid bounded even when cmux.json contains a
        // very large (but schema-valid) Vault registry. Built-ins occupy their
        // slots first; user registrations fill only the remaining capacity.
        let remainingCapacity = max(
            0,
            NotificationSoundOverrides.maximumAgentCount - optionsByID.count
        )
        var addedRegistrations = 0
        for registration in registry.registrations.prefix(
            NotificationSoundOverrides.maximumAgentCount
        ) {
            guard NotificationSoundOverrideContext.isValidAgentID(registration.id) else {
                continue
            }
            if optionsByID[registration.id] == nil {
                guard addedRegistrations < remainingCapacity else { break }
                addedRegistrations += 1
            }
            optionsByID[registration.id] = NotificationSoundAgentOption(
                id: registration.id,
                displayName: registration.name
            )
        }
        return Array(
            optionsByID.values.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }.prefix(NotificationSoundOverrides.maximumAgentCount)
        )
    }
}
