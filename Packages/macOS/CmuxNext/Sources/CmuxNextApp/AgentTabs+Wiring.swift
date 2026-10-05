import CmuxNextDaemon
import Foundation

/// Agent chat tabs on the workspace store (cmux-tui/spec/commands.md, new-conversation-tab): the store
/// commands the tabs' view store sends, and where it looks up their records.
extension AgentTabStore {
    /// An empty workspace's explicit New action creates the chat page directly,
    /// so no temporary shell or bare terminal flashes behind the page.
    func openFirstPage(in workspace: WorkspaceModel, on daemon: DaemonService, services: AppServices) async throws -> SurfaceID? {
        guard let connection = daemon.connection, let localHost, canHost(on: daemon) else { throw DaemonError.notConnected }
        let record = AgentSessionRef(host: localHost, hostName: localHostName)
        let request = NewConversationTabRequest(agentSession: record, workspace: workspace.handle, origin: Self.createOrigin, mutationID: UUID().uuidString)
        let response = try await connection.request(request)
        let key = response.tabResourceID?.rawValue ?? "surface:\(response.surface.rawValue)"
        var page = NewTabPage.page(services, selected: nil)
        page.cwd = daemon.defaultCwd
        let handler = NewTabPage.handler(services, cwd: daemon.defaultCwd) { [weak services] key, request in
            guard let services, let (_, pane) = services.locateTab(key), let controller = services.paneController(for: pane) else { return }
            NewTabPage.replace(key, with: request, cwd: request.cwd ?? daemon.defaultCwd, in: controller)
        }
        newTabPages[key] = (page, handler)
        track(key, in: daemon.store)
        views[key]?.adoptNewTab(page)
        return response.surface
    }

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
            let created = AgentTabCreated(key: response.tabResourceID?.rawValue ?? "surface:\(response.surface.rawValue)",
                                          surface: response.surface)
            // Every event the daemon sent before the reply: the provisional tab settles there.
            return (created, await connection.eventSequence())
        }
        tabs.bind = { [weak services] key, expected, session, done in
            guard let services, let (tab, _) = services.locateTab(key), let connection = services.machines.daemon(forTab: tab).connection else {
                return done(.failed)
            }
            let request = BindConversationTabSessionRequest(surface: tab.surface, session: session, expectedSession: expected)
            let logger = services.daemon.logger
            // task-owner: one compare-and-swap; its answer settles the tab's sent session
            Task {
                do {
                    _ = try await connection.request(request)
                    done(.taken)
                } catch {
                    let text = String(describing: error)
                    logger.error("bind-conversation-tab-session: \(text, privacy: .public)")
                    done(text.contains(BindConversationTabSessionRequest.conflictPrefix) ? .conflict : .failed)
                }
            }
        }
        // task-owner: one read of this Mac's name, shown to Macs that see its tabs
        Task { [weak tabs] in
            let name = await MacName.computerName()
            tabs?.localHostName = name
        }
        services.madeAgentTabs = tabs
        return tabs
    }
}
