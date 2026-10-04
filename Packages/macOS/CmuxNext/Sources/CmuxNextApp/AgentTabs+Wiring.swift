import CmuxNextDaemon
import Foundation

/// Agent chat tabs on the workspace store (cmux-tui/spec/commands.md, new-conversation-tab): the store
/// commands the tabs' view store sends, and where it looks up their records.
extension AgentTabStore {
    /// The agent tabs' view store of `services`, wired to every machine's tree and daemon.
    static func wired(to services: AppServices) -> AgentTabStore {
        let tabs = AgentTabStore(tag: services.environment.tag, registry: services.registry,
                                 environment: ProcessInfo.processInfo.environment, showcase: services.environment.showcase,
                                 linkScheme: services.linkScheme, git: services.agentGit, settings: services.settings)
        // This Mac's stable install id (the Cloud device id): only this host attaches to its acpmux.
        tabs.resolveLocalHost = { [weak services] in
            guard let services else { return nil }
            guard let id = try? services.cloud.localDeviceID() else {
                services.daemon.logger.error("agent tabs: no install id, new agent tabs are refused")
                return nil
            }
            return AgentSessionRef.host(installID: id)
        }
        tabs.lookup = { [weak services] key in
            guard let services, let (tab, _) = services.locateTab(key), let record = tab.agentSession else { return nil }
            return (record: record, store: services.machines.daemon(forTab: tab).store)
        }
        tabs.listTabs = { [weak services] in
            guard let services else { return [] }
            return services.machines.allWorkspaces.flatMap { workspace, _ in
                workspace.screens.flatMap(\.panes).flatMap(\.tabs).compactMap { tab in tab.agentSession.map { (key: tab.id, record: $0) } }
            }
        }
        tabs.create = { pane, daemon, record, key in
            guard let connection = daemon.connection else { throw DaemonError.notConnected }
            let request = NewConversationTabRequest(agentSession: record, pane: pane, origin: createOrigin, mutationID: key)
            let response = try await connection.request(request)
            return AgentTabCreated(key: response.tabResourceID?.rawValue ?? "surface:\(response.surface.rawValue)", surface: response.surface)
        }
        tabs.bind = { [weak services] key, session in
            guard let services, let (tab, _) = services.locateTab(key) else { return }
            let daemon = services.machines.daemon(forTab: tab)
            let surface = tab.surface
            services.registry.track(Task {
                let ok = await daemon.run(BindConversationTabSessionRequest.command) { connection in
                    _ = try await connection.request(BindConversationTabSessionRequest(surface: surface, session: session))
                }
                return ok ? nil : "bind-conversation-tab-session failed (see the app log)"
            })
        }
        services.madeAgentTabs = tabs
        return tabs
    }
}
