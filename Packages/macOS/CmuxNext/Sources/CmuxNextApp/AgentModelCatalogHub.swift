import CmuxNextAgentPane
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// The composer's model catalog (decision M2) for every agent page: one ``AgentModelCatalogStore``
/// read from this app's acpmux (which fetches it for every client), answered with cmux.json
/// `agentPane.models` as the user layer, and pushed to open pages when acpmux announces a new
/// catalog (`catalog.changed`), a refresh brings one, or the user edits `agentPane.models`.
@MainActor
final class AgentModelCatalogHub {
    let store: AgentModelCatalogStore
    private(set) var user: JSONValue?
    /// The open pages a change is pushed to.
    private let pages: () -> [AgentPaneView]
    private var settingsTask: Task<Void, Never>?
    private var acpmuxTask: Task<Void, Never>?

    init(source: AcpmuxModelCatalogSource?, settings: SettingsController?, pages: @escaping () -> [AgentPaneView]) {
        store = AgentModelCatalogStore(source: source)
        self.pages = pages
        if let settings { settingsTask = followSettings(settings) }
        if let source { acpmuxTask = followAcpmux(source) }
    }

    /// The catalog source for this app's acpmux, or nil when the app runs a mock host or has no acpmux.
    static func source(tag: String?, environment: [String: String], showcase: Bool) -> AcpmuxModelCatalogSource? {
        if showcase || environment["CMUX_NEXT_AGENT_PANE_MOCK"] == "1" { return nil }
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        guard let acpmux = AgentTabStore.paneEnvironment(tag: tag, bundledBinDirectory: bin, environment: environment) else { return nil }
        return AcpmuxModelCatalogSource(socketPath: acpmux.socketPath)
    }

    /// Ends both followers (the tabs are going away).
    func stop() {
        settingsTask?.cancel()
        acpmuxTask?.cancel()
    }

    /// `models.catalog` for `model`'s page.
    func wire(_ model: AgentPaneModel) {
        model.onModelCatalog = { [weak self] refresh in
            guard let self else { return AgentModelCatalogStore.reply(catalog: nil, delivery: nil, user: nil) }
            return await reply(refresh: refresh)
        }
    }

    /// `{catalog, delivery, user}`; a reply that saw a new catalog also reaches the other pages.
    func reply(refresh: Bool) async -> JSONValue {
        let user = user
        let result = await store.current(refresh: refresh, remote: AgentModelCatalogStore.remoteEnabled(user))
        let value = AgentModelCatalogStore.reply(catalog: result.catalog, delivery: result.delivery, user: user)
        if result.changed { broadcast(value) }
        return value
    }

    private func broadcast(_ value: JSONValue) {
        for page in pages() { page.pushModelCatalog(value) }
    }

    /// Follows `agentPane.models` in cmux.json; each change reaches every open page.
    private func followSettings(_ settings: SettingsController) -> Task<Void, Never> {
        // task-owner: lives as long as the tabs (stop()); event-driven (Observation)
        Task { [weak self] in
            var first = true
            for await user in Observations({ settings.snapshot.root.value(at: AgentModelCatalogStore.configPath) }) {
                guard let self else { return }
                self.user = user
                if first { first = false; continue }
                broadcast(await reply(refresh: false))
            }
        }
    }

    /// Follows acpmux's `catalog.changed`. A closed connection (acpmux restarting) is opened again
    /// after a ``Backoff`` wait, which stop() cancels; a delivered change resets it.
    private func followAcpmux(_ source: AcpmuxModelCatalogSource) -> Task<Void, Never> {
        // task-owner: lives as long as the tabs (stop()); event-driven (acpmux notifications), Backoff on disconnect
        Task { [weak self] in
            var backoff = Backoff(initial: .seconds(1), maximum: .seconds(60))
            // wakeup-allow: each pass awaits acpmux notifications until EOF, then one Backoff wait
            while !Task.isCancelled, self != nil {
                do {
                    for try await _ in source.changes() {
                        backoff.reset()
                        guard let self else { return }
                        _ = await reply(refresh: false)
                    }
                } catch {}
                // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
                do { try await backoff.wait(owner: "agent-pane.model-catalog.reconnect") } catch { return }
            }
        }
    }
}
