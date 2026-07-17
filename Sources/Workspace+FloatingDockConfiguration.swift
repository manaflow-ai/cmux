import Foundation

extension Workspace {
    func ensureFloatingDockConfigurationLoaded() {
        let store = floatingDockConfigurationStore()
        store.setRootDirectory(currentDirectory)
        store.ensureLoaded()
    }

    func floatingDockConfigurationStore() -> DockSplitStore {
        if let existing = _floatingDockConfigurationStore {
            return existing
        }
        let store = DockSplitStore(
            workspaceId: id,
            scope: .workspace,
            appliesControlSeed: false,
            registersForRouting: false,
            baseDirectoryProvider: { [weak self] in self?.currentDirectory },
            remoteBrowserSettingsProvider: { [weak self] in
                self?.dockRemoteBrowserSettingsSnapshot() ?? .local
            },
            onConfigurationResolved: { [weak self] resolution in
                guard let self else { return }
                self.applyFloatingDockConfiguration(resolution)
                if let owningTabManager {
                    AppDelegate.shared?.refreshWorkspaceFloatingDocks(for: owningTabManager)
                }
            }
        )
        _floatingDockConfigurationStore = store
        return store
    }

    func applyFloatingDockConfiguration(_ resolution: DockConfigResolution) {
        guard resolution.isProjectSource,
              let sourceIdentifier = resolution.floatingDockSeedSourceIdentifier else {
            return
        }

        for (index, definition) in resolution.floats.enumerated() {
            let identity = Self.floatingDockConfigurationSeedIdentity(
                sourceIdentifier: sourceIdentifier,
                floatID: definition.id
            )
            guard !seededFloatingDockConfigurationIdentities.contains(identity) else {
                continue
            }
            guard createFloatingDock(
                title: definition.title,
                frame: definition.resolvedFrame(cascadeIndex: index),
                configurationSeedIdentity: identity,
                configurationContent: definition.content,
                configurationBaseDirectory: resolution.baseDirectory
            ) != nil else {
                continue
            }
            seededFloatingDockConfigurationIdentities.insert(identity)
        }
    }

    private static func floatingDockConfigurationSeedIdentity(
        sourceIdentifier: String,
        floatID: String
    ) -> String {
        "\(sourceIdentifier.utf8.count):\(sourceIdentifier)\(floatID)"
    }
}
