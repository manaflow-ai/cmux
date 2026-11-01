import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextWorkspaceRepair
import Foundation

/// A person's Cmd-N on this Mac (instant-new-surfaces): the new workspace and its New Tab page
/// show in the key's frame as a store intent (`Intent.createWorkspace`), under the key and name
/// the create sends; `create-workspace` and its first tab (`new-conversation-tab {workspace,
/// transaction}`) run behind, and the daemon's workspace and tab take the stand-ins over in place.
/// Nothing on the key path awaits the daemon. A refused or failed create removes the workspace
/// again (the caller reports why) and closes a half-created one.
extension AgentTabStore {
    /// The stand-in shown now, and the daemon work to run (in the window's create lane).
    struct OptimisticWorkspace {
        /// The provisional first tab's key (``ProvisionalTab``).
        let tabKey: String
        let transaction: ClientTransactionID
        /// Sends the two requests, asking again on a late reply until the instant given (the press's
        /// one budget); returns the workspace key. Throws when they failed (the stand-in is gone then).
        let confirm: @MainActor (ContinuousClock.Instant) async throws -> String
        /// The create never ran (a close took it first): the stand-in goes.
        let abandon: @MainActor () -> Void
    }

    /// Whether Cmd-N on `daemon` can show its workspace before the daemon answers: this Mac's
    /// daemon, which hosts the New Tab page.
    func showsWorkspaceAtOnce(on daemon: DaemonService) -> Bool {
        daemon.isLocal && localHost != nil && canHost(on: daemon)
    }

    /// Shows workspace `key` named `name` with its New Tab page (starting in `cwd`; `token` is the
    /// key hold of the press) at daemon-order `index` in this turn, and returns the work that
    /// confirms it; with `chat` (a seed) or `session` (`linked`: ``linkedSessions``), that chat (P4).
    /// Nil when it cannot (``showsWorkspaceAtOnce(on:)``).
    func showWorkspace(_ key: WorkspaceKey, name: String, index: Int?, cwd: String?, token: String?, chat: AgentPaneSeed? = nil,
                       session: (id: String, host: String?, linked: Bool)? = nil, on daemon: DaemonService, repair: EmptyWorkspaceRepair) -> OptimisticWorkspace? {
        guard showsWorkspaceAtOnce(on: daemon), let localHost else { return nil }
        let store = daemon.store
        let record = AgentSessionRef(host: session?.host ?? localHost, hostName: localHostName, session: session?.id)
        let provisional = ProvisionalTab()
        let tabKey = provisional.id
        let snapshot = provisional.conversation(ConversationTabRef(agentSession: record))
        let transaction = ClientTransactionID.generate()
        store.onTabCreated = { [weak self] provisional, tab in
            self?.tabCreated(provisional, as: AgentTabCreated(key: tab.id, surface: tab.surface))
        }
        BenchSpans.measure("cmdN.intend") {
            store.intend(.createWorkspace(provisional: ProvisionalWorkspace(key: key, name: name, tab: snapshot), index: index),
                         transaction: transaction)
        }
        sessions[tabKey] = session?.id
        if session?.linked == true { linkedSessions.insert(tabKey) }
        if session == nil { seeds[tabKey] = AgentPaneSeedSource(chat.map { var chat = $0; chat.cwd = chat.cwd ?? cwd; return chat } ?? AgentPaneSeed(cwd: cwd)) }
        if session == nil, chat == nil { newTabPages[tabKey] = firstPage(cwd: cwd, token: token) }
        track(tabKey, in: store)
        if let page = newTabPages[tabKey]?.page, let spare = takeSpare?() { adoptSpare(spare, key: tabKey, page: page) }
        let fail: @MainActor () -> Void = { [weak self] in
            store.rejectIntent(transaction)
            self?.release(tabKey)
        }
        let confirm: @MainActor (ContinuousClock.Instant) async throws -> String = { [weak self] giveUp in
            guard let connection = daemon.connection else { fail(); throw DaemonError.notConnected }
            do {
                let created: (AgentTabCreated, UInt64?) = try await WorkspaceCreation.createWithFirstTab(
                    key, name: name, on: connection, repair: repair, giveUp: giveUp
                ) { workspace in
                    BenchSpans.mark("cmdN.workspace.created")
                    var request = NewConversationTabRequest(agentSession: record, workspace: workspace.workspace, origin: Self.createOrigin,
                                                            mutationID: UUID().uuidString)
                    request.transaction = transaction
                    // One mutation id for every send: a tab the daemon made after the deadline replays.
                    let response = try await DaemonConnection.retryingLateReplies(NewConversationTabRequest.command, until: giveUp) { try await connection.request(request) }
                    BenchSpans.mark("cmdN.tab.created")
                    let tab = AgentTabCreated(key: response.tabResourceID?.rawValue ?? "surface:\(response.surface.rawValue)",
                                              surface: response.surface)
                    return (tab, await connection.eventSequence())
                }
                self?.tabCreated(tabKey, as: created.0)
                ProvisionalTab.created(transaction, surface: created.0.surface, in: store)
                if let sequence = created.1 { store.noteSettled(transaction, at: sequence) } else { store.noteSettledAtNextSnapshot(transaction) }
                return key.rawValue
            } catch {
                fail()
                throw error
            }
        }
        return OptimisticWorkspace(tabKey: tabKey, transaction: transaction, confirm: confirm, abandon: fail)
    }
}
