import CmuxNextAgentPane
import CmuxNextSettings
import Foundation

/// The composer's model catalog (decision M2): one ``AgentModelCatalogStore`` for every agent tab,
/// answered with cmux.json `agentPane.models` as the user layer, and pushed to open pages when a
/// refresh brings a new catalog or the user edits `agentPane.models`.
extension AgentTabStore {
    /// The store for this build: `<api>/api/models/catalog`, cached in Application Support.
    static func modelCatalogStore(apiBaseURL: URL, bundleID: String?) -> AgentModelCatalogStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = support.appending(path: bundleID ?? "com.cmuxterm.app.next", directoryHint: .isDirectory)
        return AgentModelCatalogStore(endpoint: apiBaseURL.appending(path: "api/models/catalog"),
                                      cacheFile: directory.appending(path: "model-catalog.json"))
    }

    func wireModelCatalog(_ model: AgentPaneModel) {
        model.onModelCatalog = { [weak self] refresh in
            guard let self else { return AgentModelCatalogStore.reply(catalog: nil, delivery: nil, user: nil) }
            return await modelCatalogReply(refresh: refresh)
        }
    }

    /// `{catalog, delivery, user}`; a fetch that brought a new catalog also reaches the other pages.
    func modelCatalogReply(refresh: Bool) async -> JSONValue {
        let user = modelCatalogUser
        guard let modelCatalog else { return AgentModelCatalogStore.reply(catalog: nil, delivery: nil, user: user) }
        let result = await modelCatalog.current(refresh: refresh, remote: AgentModelCatalogStore.remoteEnabled(user))
        let value = AgentModelCatalogStore.reply(catalog: result.catalog, delivery: result.delivery, user: user)
        if result.changed { broadcastModelCatalog(value) }
        return value
    }

    func broadcastModelCatalog(_ value: JSONValue) {
        for view in views.values { view.pushModelCatalog(value) }
        for view in standaloneViews.allObjects { view.pushModelCatalog(value) }
    }

    /// Follows `agentPane.models` in cmux.json; each change reaches every open page.
    func followModelCatalog(_ settings: SettingsController) -> Task<Void, Never> {
        // task-owner: lives as long as the tabs; event-driven (Observation)
        Task { [weak self] in
            var first = true
            for await user in Observations({ settings.snapshot.root.value(at: AgentModelCatalogStore.configPath) }) {
                guard let self else { return }
                modelCatalogUser = user
                if first { first = false; continue }
                broadcastModelCatalog(await modelCatalogReply(refresh: false))
            }
        }
    }
}
