import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextFloating
import CmuxNextHomeEngine
import struct CmuxNextLayout.MainPaneLayout
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
    /// starting in `cwd`. With `chat`, a chat seeded with it instead of the
    /// page (a person's New Agent Chat).
    func openFirstPage(workspace: WorkspaceHandle, cwd: String?, on daemon: DaemonService,
                       chat: AgentPaneSeed? = nil) async throws -> SurfaceID? {
        guard let connection = daemon.connection, let localHost, canHost(on: daemon) else { throw DaemonError.notConnected }
        // A workspace of another machine: its chat runs there (cx-k21v), never in this Mac's acpmux,
        // and it gets no New Tab page (that page runs here). Callers open a terminal there instead
        // of a first page (``opensFirstPage(on:chat:)``).
        let remote = !daemon.isLocal
        guard !remote || chat != nil else { throw DaemonError.notConnected }
        // A chat of this Mac (an outside chat it resumes, a past chat of its list) never opens in a
        // workspace of another machine (cx-k21v).
        if remote, chat?.adopt != nil || chat?.pastChat != nil { throw AgentTabRefusal(message: RefusalStrings.agentTabMachineMismatch) }
        let record: AgentSessionRef
        if remote {
            guard let registry = Self.registryHost(of: daemon) else { throw DaemonError.notConnected }
            record = AgentSessionRef(host: registry, hostName: remoteMachineName(daemon))
        } else {
            record = AgentSessionRef(host: localHost, hostName: localHostName)
        }
        let request = NewConversationTabRequest(agentSession: record, workspace: workspace, origin: Self.createOrigin, mutationID: UUID().uuidString)
        if var chat {
            chat.cwd = chat.cwd ?? cwd
            seedFirstChat(chat, in: workspace)
        }
        defer { firstChats[workspace] = nil; firstPageTokens[workspace] = nil }
        // One mutation id for every send: a tab the daemon made after the deadline replays.
        let response = try await DaemonConnection.retryingLateReplies(NewConversationTabRequest.command) { try await connection.request(request) }
        let key = response.tabResourceID?.rawValue ?? "surface:\(response.surface.rawValue)"
        if chat != nil {
            // No view took the seed while the request ran: the tab's view takes it.
            if let seed = firstChats.removeValue(forKey: workspace) { seeds[key] = seed }
            track(key, in: daemon.store)
            return response.surface
        }
        seeds[key] = AgentPaneSeedSource(AgentPaneSeed(cwd: cwd))
        let made = firstPage(cwd: cwd, token: firstPageTokens[workspace])
        // The tree listed the tab first and its view already shows the page (with this
        // workspace's token): it keeps that page, since a new one remounts the screen and drops
        // what was typed (cx-kql5h); only the actions take this folder.
        if let shown = newTabPages[key], let made, views[key]?.model.newTab != nil {
            newTabPages[key] = (page: shown.page, handler: made.handler)
            track(key, in: daemon.store)
            return response.surface
        }
        newTabPages[key] = made
        // The tree can list the tab before this reply, and a pane showing it
        // then made a plain chat: it becomes the page now, unless it already has a session.
        if let view = views[key], let page = newTabPages[key]?.page {
            view.becomeNewTab(page)
            if view.model.newTab == nil { newTabPages[key] = nil }
        }
        track(key, in: daemon.store)
        return response.surface
    }

    /// Whether a new or empty workspace of `daemon` opens with an agent tab: this Mac's opens the
    /// New Tab page; another machine's opens only a chat it asked for (its terminal otherwise).
    func opensFirstPage(on daemon: DaemonService, chat: Bool = false) -> Bool { canHost(on: daemon) && (daemon.isLocal || chat) }

    /// The chat seed of new `workspace`, held before its tab is known: the
    /// tree can list the tab before new-conversation-tab replies, and a view
    /// built then takes it (``firstChatSeed(of:in:)``).
    func seedFirstChat(_ seed: AgentPaneSeed, in workspace: WorkspaceHandle) { firstChats[workspace] = AgentPaneSeedSource(seed) }

    /// A new workspace's first New Tab page, carrying that workspace's key-hold token.
    func firstPage(cwd: String?, token: String?) -> (page: AgentPaneNewTab, handler: NewTabPageHandler)? {
        guard var made = firstPageNewTab?(cwd, nil) else { return nil }
        if let token {
            made.page.inputToken = token
            onFirstPageToken?(token)
        }
        return made
    }

    /// The key-hold token of the new workspace holding tab `key` (kept until its create returns).
    func firstPageToken(of key: String, in store: DaemonStore) -> String? {
        guard !firstPageTokens.isEmpty, let tab = store.tab(id: key), let pane = store.pane(containing: tab.surface),
              let workspace = store.workspace(containing: pane.handle) else { return nil }
        return firstPageTokens[workspace.handle]
    }

    /// The held seed of the new workspace holding tab `key`, taken once.
    func firstChatSeed(of key: String, in store: DaemonStore) -> AgentPaneSeedSource? {
        guard !firstChats.isEmpty, let tab = store.tab(id: key), let pane = store.pane(containing: tab.surface),
              let workspace = store.workspace(containing: pane.handle) else { return nil }
        return firstChats.removeValue(forKey: workspace.handle)
    }

    /// The agent tabs' view store of `services`, wired to every machine's tree and daemon.
    static func wired(to services: AppServices) -> AgentTabStore {
        let tabs = AgentTabStore(build: services.environment.build, registry: services.registry, environment: services.agentPaneEnvironment ?? ProcessInfo.processInfo.environment, showcase: services.environment.showcase,
                                 linkScheme: services.linkScheme, settings: services.settings, openPanel: services.openPanel)
        tabs.launchImages = services.launchImages
        tabs.agentAvatars = AgentAvatars(uploads: services.chiefAvatarUploads, openPanel: services.openPanel)
        let state = services.environment.sidebarSnapshotFile?.url.deletingLastPathComponent()
        tabs.unsentDrafts = AgentUnsentDrafts(directory: state, work: services.work)
        tabs.pageChats.environments = state.map { SavedEnvironments(url: $0.appending(path: "environments.json")) }
        // The environment picker's Cloud machines: the account's, with Open and Resume (`cloudMachine.*`).
        AgentPaneCloudMachines.shared.wire(services)
        // The composer chips and shell commands chat pages held at the last quit (every relaunch's quit).
        tabs.relaunchWake = services.relaunchWake
        // The Chief home's acpmux: the Chief host's subagent tabs attach there.
        let home = ChiefHome.resolve(tag: services.environment.tag)
        let chief = ChiefHomeAcpmux(home: home, local: tabs.host, ensureHost: { [weak services] in
            await MainActor.run { _ = services?.home.brain.ensure(asked: false) }
        }, startHost: { [weak services] in
            await MainActor.run { services?.home.brain.ensureForChat() ?? false }
        })
        (tabs.chiefHost, tabs.chiefPaneHost) = (chief.host, chief.paneHost)
        // A subagent tab made under another Chief home of this Mac attaches there (#25262).
        tabs.chiefHomes = ChiefHomeDirectory(parents: ChiefHomeDirectory.homeParents(of: home), work: services.work,
                                             environment: { ChiefHomeAcpmux.environment(home: $0) })
        tabs.localSessionHost = chief.localRouter(tabs.host)
        // This Mac's stable install id (the Cloud device id): only this host attaches to its acpmux.
        tabs.blankChatHandler = { [weak services] key in
            guard let services, let (tab, pane) = services.locateTab(key), let controller = services.paneController(for: pane) else { return nil }
            // A chat tab has no daemon folder: its own exact folder (a shell block's Open in Terminal, cx-zld).
            let cwd = tab.cwd ?? NewTerminalStart.folder(of: tab, services: services)
            return NewTabPage.handler(services, cwd: cwd) { [weak controller, weak tabs] key, request in
                guard let controller else { return }
                NewTabPage.replace(key, with: request, cwd: request.cwd ?? cwd, in: controller, keep: tabs?.sessions[key] != nil)
            }
        }
        tabs.firstPageNewTab = { [weak services] cwd, beside in
            guard let services else { return nil }
            // A page beside a chat of another machine shows that machine's folders (cx-k21v).
            // (A chat of this Mac keeps the plain page, as before.)
            let tab = beside.flatMap { services.locateTab($0)?.0 }.flatMap { services.machines.daemon(forTab: $0).isLocal ? nil : $0 }
            var page = NewTabPage.page(services, selected: tab)
            page.cwd = cwd ?? page.cwd
            // Keys typed since Cmd-N wait for this page's field (NewTabInputCoordinator, cx-kql5h);
            // the token comes per workspace (``firstPage(cwd:token:)``).
            let input = services.keyRouter.newTabInputCoordinator
            var handler = NewTabPage.handler(services, cwd: cwd) { [weak services] key, request in
                guard let services, let (tab, pane) = services.locateTab(key), let controller = services.paneController(for: pane) else { return }
                NewTabPage.replace(key, with: request, cwd: request.cwd ?? tab.cwd, in: controller)
            }
            handler.inputReady = { [weak input] key, token in input?.pageReady(token, key: key) }
            return (page, handler)
        }
        tabs.onFirstPageToken = { [weak services] token in services?.keyRouter.newTabInputCoordinator.attachIncoming(token) }
        tabs.resolveLocalHost = { [weak services] in
            guard let services else { return nil }
            guard let id = try? services.cloud.localDeviceID() else { services.daemon.logger.error("agent tabs: no install id, new agent tabs are refused"); return nil }
            return AgentSessionRef.host(installID: id)
        }
        tabs.openProcess = { [weak services] chat, viewer in
            guard let services else { return false }
            return AgentProcessTerminal(services: services).open(viewer, beside: chat)
        }
        // App-server `vm_…` IDs use a different backend contract; hide the transfer action
        // until that backend exposes the credential delivery operation. Legacy provider VMs use
        // the pinned `/api/vm/{id}/exec` path below.
        tabs.syncCloudCredentialTransferAvailability(services: services)
        // A pane may outlive the Cloud teardown. Clear the action handler as soon as sign-out
        // begins so an already-open page cannot call a recovery action that native recovery rejects.
        services.cloud.willSignOut.append { [weak tabs] in tabs?.cloudCredentialTransfer = nil }
        // A chat in a plain split (chat | terminal) gets a tab in the pane already on its right; the
        // side pane (AgentSidePanes) reuses only a pane it made, so it would make a third split.
        // A pane of another machine holds no chat of this Mac's acpmux: nothing opens there.
        tabs.openRight = { [weak services, weak tabs] chat, session in
            guard let services, let tabs, let (_, pane) = services.locateTab(chat), let source = services.paneController(for: pane) else { return false }
            return services.linkOpener.open(from: source) { target, placed in
                guard target.daemon.isLocal else { return false }
                return tabs.openTab(in: target, session: session, select: placed == nil) { [weak services, weak tabs] key in
                    // task-owner: one creation reply; ends after tree arrival, cancellation or the mirror deadline
                    Task { [weak services, weak tabs] in
                        guard let tabs else { return }
                        await TabMirror.performWhenReached(key, in: tabs.locate) {
                            if let placed { if let surface = services?.locateTab(key)?.0.surface { placed(surface) }; return }
                            _ = tabs.actionRegistry?.perform("tab.focus", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: key), origin: .user))
                        }
                    }
                }
            }
        }
        tabs.lookup = { [weak services] key in
            guard let services, let (tab, _) = services.locateTab(key), let record = tab.agentSession else { return nil }
            return (record: record, store: services.machines.daemon(forTab: tab).store)
        }
        tabs.locate = { [weak services] key in
            guard let services, let (tab, pane) = services.locateTab(key) else { return nil }
            return (pane: pane.handle, daemon: services.machines.daemon(forTab: tab))
        }
        tabs.openInMainPane = { [weak services] chat, focus, open, created, finished in
            guard let services, let (_, pane) = services.locateTab(chat), let controller = services.paneController(for: pane),
                  let side = MainPaneLayout.side(from: controller, services: services) else { return nil }
            return MainPaneLayout.openAgentTab(from: controller, side: side, focus: focus, services: services, open: open,
                                         created: created, finished: finished)
        }
        // A redeemed Run attempt's terminal opens only on a Cloud machine (keyed by its provider VM
        // id) whose daemon this Mac already has connected, with the session the ticket names; never
        // on this Mac, an SSH host or a paired server. The page's ids are not verified against the
        // Run API here, so this is the boundary. The tab's own daemon stores the remote-terminal
        // reference (RemoteTerminalService.openTerminal does the same).
        tabs.runAttach = { [weak services] key, request in
            let vm = request.providerVMID, tabsCapability = DaemonCapability.remoteTerminalTabs.rawValue
            guard let services, let (_, pane) = services.locateTab(key) else { throw DaemonError.notConnected }
            let home = services.machines.daemon(forPane: pane)
            guard let homeConnection = home.connection, services.machines.session(vm) != nil, let worker = services.machines.daemon(machine: vm), !worker.isLocal,
                  worker.connection != nil, let identity = worker.identity, let sessionID = identity.sessionID, identity.session == request.session else { throw DaemonError.notConnected }
            guard home.supports(tabsCapability) else { throw DaemonError.missingCapabilities([tabsCapability]) }
            let name = services.machines.machineName(vm) ?? vm
            let ref = RemoteTerminalRef(sessionID: sessionID, terminalID: TerminalID(rawValue: request.providerTerminalID), sessionName: name)
            _ = try await homeConnection.newRemoteTerminalTab(ref, in: pane.handle, title: RemoteStrings.terminalOn(name))
        }
        // A tab's git reads (Changes, file search) go to the machine whose acpmux runs its session
        // (AgentPaneHostKind): a Cloud or SSH machine's session reads its folder there (cx-d0tq).
        tabs.gitLink = { [weak services, weak tabs] key in
            guard let services else { return nil }
            guard let tabs, let (tab, _) = services.locateTab(key), let record = tab.agentSession,
                  AgentPaneHostKind(record, localHost: tabs.localHost, chiefHost: tabs.chiefHost,
                                    listedHere: services.machines.daemon(forTab: tab).isLocal) == .remote else { return services.agentGit.local }
            // A tab naming another machine than the one listing it reads nothing (never this Mac's folder).
            guard let daemon = try? services.machines.agentDaemon(forTab: tab) else { return nil }
            return services.agentGit.link(for: daemon)
        }
        tabs.remoteMachineName = { [weak services] daemon in
            services?.machines.machineName(daemon.machineID).flatMap(AgentTabStore.displayName)
        }
        // A new chat on another machine with no folder in its seed starts in a folder of its
        // workspace there (a terminal's), never a folder of this Mac.
        tabs.remoteFolder = { [weak services] key in
            guard let services, let (_, pane) = services.locateTab(key) else { return nil }
            return services.machines.daemon(forPane: pane).store.workspace(containing: pane.handle)?.firstTabFolder
        }
        tabs.remoteFolders = { [weak services] key in
            guard let services, let (tab, _) = services.locateTab(key) else { return [] }
            return services.machines.daemon(forTab: tab).store.tabFolders
        }
        tabs.remoteHost = { [weak services, weak tabs] key in
            guard let services, let tabs, let (tab, _) = services.locateTab(key), let record = tab.agentSession else { return nil }
            let started = record.host.hasPrefix(AgentTabRemoteStart.registryPrefix)
            let daemon: DaemonService
            do {
                daemon = try services.machines.agentDaemon(forTab: tab)
            } catch {
                return AgentTabRefusedHost(refusal: AgentRemoteStartRefusal(code: AgentRemoteStartRefusal.hostMismatchCode, machine: record.hostName ?? ""))
            }
            let machine = record.hostName ?? services.machines.machineName(daemon.machineID) ?? daemon.machineID
            let session = record.session ?? tabs.sessions[tabs.resolve(key)]
            guard !daemon.isLocal, daemon.supports(DaemonCapability.agentSessionAttach.rawValue), let endpoint = daemon.remoteEndpoint else {
                // A chat this app started on that machine says what to do there; an older tab
                // recorded for another Mac keeps the "runs on" notice.
                guard started else { return nil }
                return AgentTabRefusedHost(refusal: .startUnsupported(machine: machine))
            }
            var host = AgentTabRemoteHost(surface: tab.surface.rawValue, session: session, machine: machine, endpoint: endpoint, servesTrust: daemon.supports(DaemonCapability.agentSessionTrust.rawValue),
                                           servesKeyedReason: daemon.supports(DaemonCapability.agentSessionStartKeyedReason.rawValue))
            host.cloudMachineID = services.machines.session(daemon.machineID)?.machineID
            host.cloudCredentialRecoveryAvailable = host.cloudMachineID != nil &&
                services.cloud.auth.isSignedIn && services.cloud.configuration.linkSource == .legacy
            if started {
                // The tab may still be provisional here: each handshake reads its store surface.
                host.existing = { [weak tabs] in
                    guard let tabs else { throw CancellationError() }
                    return try await tabs.existingRemoteChat(key)
                }
            }
            if session == nil {
                // Only a new chat this app opened on that machine starts there, and only through a
                // daemon that serves the verb; never a fallback to this Mac (cx-k21v). It starts at
                // the page's first send, never when the tab opens.
                guard started else { return nil }
                guard daemon.supports(DaemonCapability.agentSessionStart.rawValue) else { return AgentTabRefusedHost(refusal: .startUnsupported(machine: machine)) }
                // A Cloud machine (the app's own record, never the guest's) starts a chat only on
                // the Cloud API's owner answer on the link the start goes over, checked as it is
                // sent, through any daemon (an app-server link has none: no owner word).
                let cloudLink: CloudMachineLink?? = services.machines.session(daemon.machineID).map(\.link)
                let ownerLink = cloudLink.map { link -> AgentSessionAttachClient.OwnerLink in { await link?.ownerLink } }
                host.start = { [weak tabs] cwd, harness, personKey in
                    guard let tabs else { throw CancellationError() }
                    return try await tabs.startRemoteChat(key, machine: machine, cwd: cwd, harness: harness, personKey: personKey,
                                                          ownerLink: ownerLink, endpoint: endpoint)
                }
            }
            // cx-0q7o: the app's own ssh exec to that machine restarts its acpmux with a key.
            if let link = services.machines.sshSession(daemon.machineID) ?? services.machines.server(daemon.machineID)?.link {
                host.approvals = AgentPaneRemoteApprovals(machineID: link.machineID, label: link.host.label, restart: { [weak services, weak link] in
                    guard let services, let link else { return .failed("") }
                    return await services.ssh.restartWithApprovals(link)
                }, prepare: { [weak services, weak link] preparation in
                    guard let services, let link else { return false }
                    return await services.ssh.restartWithApprovalsIfIdle(link, preparation)
                })
            } else if let cloud = services.machines.session(daemon.machineID), cloud.link != nil || cloud.appLink != nil {
                // cx-psxg: a Cloud machine on the /api/vm link, through the web Cloud service; cx-kvmz:
                // one on the Cloud app server link, through the API Worker with the person's session.
                host.approvals = AgentPaneRemoteApprovals(machineID: cloud.machineID, label: cloud.machine.title) { [weak services, weak cloud] in
                    guard let services, let cloud else { return .failed("") }
                    return await services.cloud.restartWithApprovals(cloud)
                }
            }
            return host
        }
        tabs.listTabs = { [weak services] in
            guard let services else { return [] }
            return services.machines.allWorkspaces.flatMap { workspace, _ in
                workspace.screens.flatMap(\.panes).flatMap(\.tabs).compactMap { tab in tab.agentSession.map { (key: tab.id, record: $0) } }
            }
        }
        tabs.create = { pane, daemon, record, key, transaction, split in
            guard let connection = daemon.connection else { throw DaemonError.notConnected }
            var request = NewConversationTabRequest(agentSession: record, pane: pane, origin: createOrigin, mutationID: key,
                                                    transaction: transaction)
            request.split = split
            let response = try await connection.request(request)
            let created = AgentTabCreated(key: response.tabResourceID?.rawValue ?? "surface:\(response.surface.rawValue)",
                                          surface: response.surface)
            // Every event the daemon sent before the reply: the provisional tab settles there.
            return (created, await connection.eventSequence())
        }
        tabs.daemonForTab = { [weak services] key in
            guard let services, let (tab, _) = services.locateTab(key) else { return nil }
            return services.machines.daemon(forTab: tab)
        }
        tabs.daemonListing = { [weak services] tab in services?.machines.daemon(forTab: tab) }
        tabs.moveSelection = { [weak services] provisional, surface in
            for controller in services?.windows.controllers ?? [] {
                guard let panes = controller.content?.panes.values else { continue }
                for pane in panes where pane.stripModel.selectedID?.rawValue == provisional {
                    pane.selectWhenReported(surface: surface)
                }
            }
        }
        tabs.bind = { [weak services] key, surface, expected, session, harness in
            guard let services, let (tab, _) = services.locateTab(key), let connection = services.machines.daemon(forTab: tab).connection else { return (.failed, nil) }
            let request = BindConversationTabSessionRequest(surface: surface, session: session, expectedSession: expected, harness: harness)
            let outcome: AgentSessionBindOutcome, sequence: UInt64? // one return: swiftlang/swift#92698 (cx-21wc5)
            do {
                _ = try await connection.request(request)
                (outcome, sequence) = (.taken, await connection.eventSequence())
            } catch {
                let text = String(describing: error)
                services.daemon.logger.error("bind-conversation-tab-session: \(text, privacy: .public)")
                (outcome, sequence) = (text.contains(BindConversationTabSessionRequest.conflictPrefix) ? .conflict : .failed, nil)
            }
            return (outcome, sequence)
        }
        // task-owner: one read of this Mac's name, shown to Macs that see its tabs and on every
        // pane's location row (a pane's handshake awaits it)
        // A showcase run and a run under capture name the showcase Mac (AppEnvironment.namesShowcaseMac).
        let showcase = services.environment.namesShowcaseMac
        AgentPaneModel.localMachineName = Task { [weak tabs] in
            let name = await AgentTabStore.localMachineName(showcase: showcase) { await MacName().displayName() }
            tabs?.localHostName = name
            return AgentPaneModel.rememberLocalMachineName(AgentTabStore.displayName(name) ?? name)
        }
        services.madeAgentTabs = tabs
        return tabs
    }

    /// The agent avatars on `model`'s page, for every agent view (tabs, spares and standalone chats):
    /// its cards ask for them, its chat menu sets and removes them over `view`'s window.
    func wireAgentAvatars(_ model: AgentPaneModel, view: AgentPaneView) {
        model.onAgentAvatar = { [weak self] session in await self?.agentAvatars?.avatar(session) }
        model.onSetAgentAvatar = { [weak self, weak view] session in
            guard let self, let agentAvatars else { return nil }
            let src = await agentAvatars.choose(session, window: view?.window)
            if src != nil { agentAvatarChanged(session) }
            return src
        }
        model.onRemoveAgentAvatar = { [weak self] session in
            self?.agentAvatars?.remove(session)
            self?.agentAvatarChanged(session)
        }
    }

    /// Every agent page (tabs and standalone chats) asks for session `session`'s avatar again: a
    /// Set or Remove in one pane reaches the cards and chips that other panes draw of the same session.
    func agentAvatarChanged(_ session: String) {
        for view in views.values { view.agentAvatarChanged(session) }
        for view in standaloneViews.allObjects { view.agentAvatarChanged(session) }
    }
}

extension AgentTabStore {
    /// Keep the native recovery callback aligned with the current Cloud account. This runs at
    /// construction and on each observed sign-in/account transition, so sign-in restores it.
    func syncCloudCredentialTransferAvailability(services: AppServices) {
        guard Self.cloudCredentialTransferIsAvailable(
            linkSource: services.cloud.configuration.linkSource,
            isSignedIn: services.cloud.auth.isSignedIn) else {
            cloudCredentialTransfer = nil
            return
        }
        cloudCredentialTransfer = { [weak services] chat, request in
            guard let services, services.cloud.auth.isSignedIn else { return false }
            return await CloudPresenter.recoverCredentials(chat: chat, request: request, services: services)
        }
    }
    static func cloudCredentialTransferIsAvailable(linkSource: CloudConfiguration.LinkSource, isSignedIn: Bool) -> Bool {
        linkSource == .legacy && isSignedIn
    }
}
