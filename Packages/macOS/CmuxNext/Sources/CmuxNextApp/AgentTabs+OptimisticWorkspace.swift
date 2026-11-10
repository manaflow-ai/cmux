import CmuxNextAgentPane
import CmuxNextTabs
import CmuxNextDaemon
import CmuxNextWorkspaceRepair
import Foundation

/// A person's Cmd-N on this Mac, or an open of a chat (instant-new-surfaces): the new workspace and its New Tab page or chat
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
    /// confirms it; with `chat` (a seed) or `session` (`linked`: ``linkedSessions``), that chat (P4); `firstTabKeyed`: its tab is keyed by the workspace (`firstChatTabMutationID`).
    /// Nil when it cannot (``showsWorkspaceAtOnce(on:)``).
    func showWorkspace(_ key: WorkspaceKey, name: String, index: Int?, cwd: String?, token: String?, chat: AgentPaneSeed? = nil,
                       session: (id: String, host: String?, linked: Bool)? = nil, firstTabKeyed: Bool = false,
                       placedBy rule: NewWorkspaceDefaultSlot? = nil, ledger: NewWorkspacePlacements.Ledger? = nil,
                       on daemon: DaemonService, repair: EmptyWorkspaceRepair) -> OptimisticWorkspace? {
        guard showsWorkspaceAtOnce(on: daemon), let localHost else { return nil }
        let store = daemon.store
        let record = AgentSessionRef(host: session?.host ?? localHost, hostName: localHostName, session: session?.id)
        // A plain Cmd-N of the workspace reserved before the key: the press gives its name, folder and key-hold token.
        let reserved = chat == nil && session == nil ? store.reservedWorkspace(keyed: key) : nil
        let provisional = ProvisionalTab()
        let snapshot = reserved?.provisional.tab ?? provisional.conversation(ConversationTabRef(agentSession: record))
        let tabKey = reserved?.tabKey ?? provisional.id
        let transaction = ClientTransactionID.generate()
        let scoped = AgentTabKey(machine: daemon.machineID, key: tabKey)
        store.onTabCreated = { [weak self, machine = daemon.machineID] provisional, tab in
            self?.tabCreated(provisional, as: AgentTabCreated(key: tab.id, surface: tab.surface), machine: machine)
        }
        BenchSpans.measure("cmdN.intend") {
            store.intend(.createWorkspace(provisional: reserved?.provisional.named(name) ?? ProvisionalWorkspace(key: key, name: name, tab: snapshot),
                                          index: index), transaction: transaction)
        }
        sessions[scoped] = session?.id
        if session?.linked == true { linkedSessions.insert(scoped) }
        if session == nil { seeds[scoped] = AgentPaneSeedSource(chat.map { var chat = $0; chat.cwd = chat.cwd ?? cwd; return chat } ?? AgentPaneSeed(cwd: cwd)) }
        let reservedPage = reserved.flatMap { _ in newTabPages[scoped]?.page }
        if session == nil, chat == nil { newTabPages[scoped] = firstPage(cwd: cwd, token: token) }
        if reserved == nil {
            track(tabKey, in: store, machine: daemon.machineID)
            if let page = newTabPages[scoped]?.page, let spare = takeSpare?(.now) { adoptSpare(spare, key: scoped, page: page) }
        } else if let page = newTabPages[scoped]?.page {
            // The reserved page takes the press's context: its token alone keeps the screen; another folder remounts it.
            if reservedPage?.drawsSameScreen(as: page) != true { BenchSpans.mark("cmdN.reserved.recontext") }
            views[scoped]?.adoptNewTab(page)
        }
        let fail: @MainActor () -> Void = { [weak self] in
            store.rejectIntent(transaction)
            self?.release(tabKey, machine: daemon.machineID)
        }
        let confirm: @MainActor (ContinuousClock.Instant) async throws -> String = { [weak self] giveUp in
            guard let connection = daemon.connection else { fail(); throw DaemonError.notConnected }
            do {
                let created: (AgentTabCreated, UInt64?) = try await WorkspaceCreation.createWithFirstTab(
                    key, name: name, placedBy: rule, ledger: ledger, on: connection, repair: repair, giveUp: giveUp
                ) { workspace in
                    BenchSpans.mark("cmdN.workspace.created")
                    let response = try await connection.newFirstTab(.firstAgentTab(record, in: workspace.workspace, origin: Self.createOrigin, mutationID: firstTabKeyed ? workspace.firstChatTabMutationID : UUID().uuidString,
                                                                                    transaction: transaction), until: giveUp)
                    BenchSpans.mark("cmdN.tab.created")
                    return (AgentTabCreated(key: response.tabKey, surface: response.surface), await connection.eventSequence())
                }
                self?.tabCreated(tabKey, as: created.0, machine: daemon.machineID)
                ProvisionalTab.created(transaction, surface: created.0.surface, in: store)
                if let sequence = created.1 { store.noteSettled(transaction, at: sequence) } else { store.noteSettledAtNextSnapshot(transaction) }
                if let started = self?.sessions[AgentTabKey(machine: daemon.machineID, key: created.0.key)] { self?.sendSession(started, for: created.0.key, machine: daemon.machineID) } // a chat its page started first binds now (as `open`)
                return key.rawValue
            } catch {
                fail()
                throw error
            }
        }
        return OptimisticWorkspace(tabKey: tabKey, transaction: transaction, confirm: confirm, abandon: fail)
    }

    /// Reserves `daemon`'s next plain Cmd-N workspace with its New Tab page in `cwd` (the spare, `.idle`: its page draws no frame; else made now); idle work only.
    func reserveWorkspace(on daemon: DaemonService, cwd: String?) -> WorkspaceModel? {
        let store = daemon.store
        if let reserved = store.reservedWorkspace { return reserved.model }
        guard showsWorkspaceAtOnce(on: daemon), let localHost, let made = firstPage(cwd: cwd, token: nil) else { return nil }
        let record = AgentSessionRef(host: localHost, hostName: localHostName, session: nil), tab = ProvisionalTab(), scoped = AgentTabKey(machine: daemon.machineID, key: tab.id)
        newTabPages[scoped] = made
        track(tab.id, in: store, machine: daemon.machineID)
        if let spare = takeSpare?(.idle) { adoptSpare(spare, key: scoped, page: made.page) } else if view(for: tab.id, machine: daemon.machineID, known: (record: record, store: store)) == nil { release(tab.id, machine: daemon.machineID); return nil }
        return store.reserveWorkspace(ProvisionalWorkspace(key: WorkspaceKey.generate(), name: "", tab: tab.conversation(ConversationTabRef(agentSession: record)))).model
    }

    /// Lets `store`'s reservation go; its page goes back to the New Tab spare pool when it can (``release(_:)``).
    func releaseReservedWorkspace(on store: DaemonStore, _ reason: ReservedWorkspaceRelease) {
        guard let tabKey = store.releaseReservedWorkspace(reason)?.tabKey else { return }
        BenchSpans.mark(reason.span)
        release(tabKey, machine: tabStores.entries.first { $0.key.key == tabKey && $0.value === store }?.key.machine)
    }
}
