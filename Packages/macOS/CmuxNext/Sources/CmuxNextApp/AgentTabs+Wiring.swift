import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// Agent chat tabs on the workspace store (cmux-tui/spec/commands.md, new-conversation-tab): the store
/// commands the tabs' view store sends, and where it looks up their records.
extension AgentTabStore {
    /// An empty workspace's New action (and a person's new workspace) opens on
    /// the New Tab page, where the kind is picked; no temporary shell appears.
    func openFirstPage(in workspace: WorkspaceModel, on daemon: DaemonService, services: AppServices) async throws -> SurfaceID? {
        try await openFirstPage(workspace: workspace.handle, cwd: daemon.defaultCwd, on: daemon)
    }

    /// The same, for a workspace this app just created (not mirrored yet),
    /// starting in `cwd`.
    func openFirstPage(workspace: WorkspaceHandle, cwd: String?, on daemon: DaemonService) async throws -> SurfaceID? {
        guard let connection = daemon.connection, let localHost, canHost(on: daemon) else { throw DaemonError.notConnected }
        let record = AgentSessionRef(host: localHost, hostName: localHostName)
        let request = NewConversationTabRequest(agentSession: record, workspace: workspace, origin: Self.createOrigin, mutationID: UUID().uuidString)
        let response = try await connection.request(request)
        let key = response.tabResourceID?.rawValue ?? "surface:\(response.surface.rawValue)"
        seeds[key] = AgentPaneSeedSource(AgentPaneSeed(cwd: cwd))
        newTabPages[key] = firstPageNewTab?(cwd)
        track(key, in: daemon.store)
        return response.surface
    }

    /// The agent tabs' view store of `services`, wired to every machine's tree and daemon.
    static func wired(to services: AppServices) -> AgentTabStore {
        let tabs = AgentTabStore(tag: services.environment.tag, registry: services.registry,
                                 environment: ProcessInfo.processInfo.environment, showcase: services.environment.showcase,
                                 linkScheme: services.linkScheme, git: services.agentGit, settings: services.settings)
        // This Mac's stable install id (the Cloud device id): only this host attaches to its acpmux.
        tabs.blankChatHandler = { [weak services] key in
            guard let services, let (tab, pane) = services.locateTab(key), let controller = services.paneController(for: pane) else { return nil }
            return NewTabPage.handler(services, cwd: tab.cwd) { [weak controller] key, request in
                guard let controller else { return }
                NewTabPage.replace(key, with: request, cwd: request.cwd ?? tab.cwd, in: controller)
            }
        }
        tabs.firstPageNewTab = { [weak services] cwd in
            guard let services else { return nil }
            var page = NewTabPage.page(services, selected: nil)
            page.cwd = cwd
            let handler = NewTabPage.handler(services, cwd: cwd) { [weak services] key, request in
                guard let services, let (tab, pane) = services.locateTab(key), let controller = services.paneController(for: pane) else { return }
                NewTabPage.replace(key, with: request, cwd: request.cwd ?? tab.cwd, in: controller)
            }
            return (page, handler)
        }
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
        tabs.create = { pane, daemon, record, key, transaction in
            guard let connection = daemon.connection else { throw DaemonError.notConnected }
            let request = NewConversationTabRequest(agentSession: record, pane: pane, origin: createOrigin, mutationID: key,
                                                    transaction: transaction)
            let response = try await connection.request(request)
            let created = AgentTabCreated(key: response.tabResourceID?.rawValue ?? "surface:\(response.surface.rawValue)",
                                          surface: response.surface)
            // Every event the daemon sent before the reply: the provisional tab settles there.
            return (created, await connection.eventSequence())
        }
        tabs.moveSelection = { [weak services] provisional, surface in
            for controller in services?.windows.controllers ?? [] {
                guard let panes = controller.content?.panes.values else { continue }
                for pane in panes where pane.stripModel.selectedID?.rawValue == provisional {
                    pane.selectWhenReported(surface: surface)
                }
            }
        }
        tabs.bind = { [weak services] key, surface, expected, session in
            guard let services, let (tab, _) = services.locateTab(key), let connection = services.machines.daemon(forTab: tab).connection else {
                return (.failed, nil)
            }
            let request = BindConversationTabSessionRequest(surface: surface, session: session, expectedSession: expected)
            do {
                _ = try await connection.request(request)
                return (.taken, await connection.eventSequence())
            } catch {
                let text = String(describing: error)
                services.daemon.logger.error("bind-conversation-tab-session: \(text, privacy: .public)")
                return (text.contains(BindConversationTabSessionRequest.conflictPrefix) ? .conflict : .failed, nil)
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
