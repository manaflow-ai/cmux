import Foundation

enum CmuxSettingsManagedEditWriter {
    static func makeWriteBackPlan(snapshot: ResolvedSettingsSnapshot) -> ManagedSettingsWriteBackPlan? {
        var changesBySourcePath: [String: [String: Any]] = [:]
        collectUserDefaultEdits(snapshot: snapshot, changesBySourcePath: &changesBySourcePath)
        collectNewUserDefaultEdits(snapshot: snapshot, changesBySourcePath: &changesBySourcePath)
        let customSocketPasswordSources = collectCustomSocketPasswordSources(snapshot: snapshot)
        guard !changesBySourcePath.isEmpty || !customSocketPasswordSources.isEmpty else { return nil }
        return ManagedSettingsWriteBackPlan(
            changesBySourcePath: changesBySourcePath,
            customSocketPasswordSources: customSocketPasswordSources
        )
    }

    private static func collectUserDefaultEdits(
        snapshot: ResolvedSettingsSnapshot,
        changesBySourcePath: inout [String: [String: Any]]
    ) {
        for (defaultsKey, managedValue) in snapshot.managedUserDefaults {
            let currentValue = managedValue.currentValue(defaultsKey: defaultsKey)
            guard currentValue != managedValue,
                  let source = snapshot.managedUserDefaultSources[defaultsKey],
                  let jsonValue = source.writeBack.jsonValue(
                    defaultsKey: defaultsKey,
                    currentValue: currentValue
                  ) else {
                continue
            }
            changesBySourcePath[source.sourcePath, default: [:]][source.jsonPath] = jsonValue
        }
    }

    private static func collectNewUserDefaultEdits(
        snapshot: ResolvedSettingsSnapshot,
        changesBySourcePath: inout [String: [String: Any]]
    ) {
        for (defaultsKey, source) in snapshot.editableUserDefaultSources where snapshot.managedUserDefaults[defaultsKey] == nil {
            guard let currentValue = source.valueKind.currentStoredValue(defaultsKey: defaultsKey),
                  snapshot.editableUserDefaults[defaultsKey] != currentValue,
                  let jsonValue = source.writeBack.jsonValue(
                    defaultsKey: defaultsKey,
                    currentValue: currentValue
                  ) else {
                continue
            }
            changesBySourcePath[source.sourcePath, default: [:]][source.jsonPath] = jsonValue
        }
    }

    private static func collectCustomSocketPasswordSources(
        snapshot: ResolvedSettingsSnapshot
    ) -> [(sourcePath: String, jsonPath: String, managedValue: ManagedStringOverride)] {
        guard let managedSocketPassword = snapshot.managedCustomSettings.socketPassword,
              let source = snapshot.managedCustomSettingSources[CmuxSettingsFileStore.socketPasswordWriteBackIdentifier]
        else {
            return []
        }
        return [(sourcePath: source.sourcePath, jsonPath: source.jsonPath, managedValue: managedSocketPassword)]
    }
}
