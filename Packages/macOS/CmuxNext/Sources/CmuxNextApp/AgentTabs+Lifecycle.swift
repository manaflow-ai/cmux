import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import Foundation

/// Opening agent chat tabs on the workspace store with zero wait, and letting their view state
/// go when the store drops them (cmux-tui/spec/commands.md, new-conversation-tab).
extension AgentTabStore {
    /// The `origin` of the app's `new-conversation-tab` requests for agent chats.
    static let createOrigin = "cmux-next-agent-tab"

    /// Adds a new agent chat tab to `pane`'s strip. The tab shows at once (R81): a create intent on the store's
    /// log shows a provisional tab until the store's tab replaces it; a refusal removes it again. View state
    /// (seed, new tab page, spare page, link) is kept under the provisional id and moves to the store's id then.
    ///
    /// - Parameters:
    ///   - pane: The pane (its daemon handle).
    ///   - daemon: The daemon that owns the pane.
    ///   - session: The acpmux session it shows; nil starts a new chat.
    ///   - seed: What a new chat inherits (cwd, a draft); ignored with a session.
    ///   - newTab: Shows the new tab page until it becomes a chat; the handler gets the terminal or browser choices and shortcut edits.
    ///   - spare: A prewarmed page (``makeSpare(_:)``) the new tab page adopts.
    ///   - linked: A `cmux://session/<id>` link opened it: its page refuses a session the daemon does not have instead of falling back.
    ///   - adopt: The outside chat it resumes (`harness:agentSessionId`).
    ///   - idempotencyKey: The creation's key; a retry with it returns the same tab. Fresh by default.
    ///   - split: The tab opens in a new pane on that side of `pane` (`conversation-tab-split-v1`): one daemon
    ///     commit, shown at once in a provisional pane, never in `pane`'s strip.
    /// - Throws: ``AgentTabRefusal`` when the pane cannot hold one (nothing is shown).
    func open(in pane: PaneID, of daemon: DaemonService, session: String? = nil, seed: AgentPaneSeedSource? = nil,
              newTab: (page: AgentPaneNewTab, handler: NewTabPageHandler)? = nil, spare: AgentPaneView? = nil,
              linked: Bool = false, adopt: AgentPaneAdopt? = nil, host: String? = nil,
              idempotencyKey: String = UUID().uuidString.lowercased(), split: SplitDirection? = nil) throws -> AgentTabPending {
        guard let localHost, holdsTabs(daemon), reachable(daemon) else {
            if let spare, recycle?(spare) != true { retirer.retire(spare) }
            let reason = !reachable(daemon) ? RefusalStrings.agentTabsDisconnected
                : localHost == nil ? RefusalStrings.agentTabCreateFailed : RefusalStrings.agentTabsUnsupported
            throw AgentTabRefusal(message: reason)
        }
        let record: AgentSessionRef
        if let refusal = Self.hostRefusal(host, localHost: localHost, chiefHost: chiefHost, daemonIsLocal: daemon.isLocal) {
            if let spare, recycle?(spare) != true { retirer.retire(spare) }
            throw AgentTabRefusal(message: refusal)
        }
        // A chat a chat of that machine started there (its daemon listed it, `agent-session-children`):
        // that machine's own chat, filed under its store, which checks it against its own list.
        let remoteChild = !daemon.isLocal && host == nil && adopt == nil
            && session.map { RemoteAgentSessionLinks.shared.parents[$0] != nil } == true
        // A session never leaves its machine (cx-k21v): a pane of another machine never gets a
        // chat of this Mac (its session, an outside chat it resumes, a past chat of this Mac's list;
        // the New Tab page's open-here included). The store binds a `registry:` tab's session only
        // through that machine's agent-session-start (cmux-tui conversation_tabs_wire.rs).
        if !daemon.isLocal, !remoteChild, session != nil || adopt != nil || seed?.namesLocalChat == true {
            if let spare, recycle?(spare) != true { retirer.retire(spare) }
            throw AgentTabRefusal(message: RefusalStrings.agentTabMachineMismatch)
        }
        // A new chat in a pane of another machine runs on that machine: the tab records that
        // machine's store as its host and its session daemon starts the chat there
        // (``startRemoteChat``), never this Mac's acpmux (cx-k21v). A session, an outside chat or
        // a past chat of this Mac was refused above.
        let remote = !daemon.isLocal && host == nil
        var seed = seed, spare = spare
        if remote {
            guard let registry = Self.registryHost(of: daemon) else {
                if let spare, recycle?(spare) != true { retirer.retire(spare) }
                throw AgentTabRefusal(message: RefusalStrings.agentTabsDisconnected)
            }
            // The same New Tab page shows (its terminal and browser choices act in this pane); its
            // chat starts on that machine at the first send (``RemoteAcpmuxWire``). A prewarmed
            // spare is connected to this Mac's acpmux, so it is never adopted here.
            if let spare, recycle?(spare) != true { retirer.retire(spare) }
            seed = remoteChild ? nil : (seed ?? AgentPaneSeedSource(AgentPaneSeed(cwd: newTab?.page.cwd)))
            spare = nil
            record = AgentSessionRef(host: registry, hostName: remoteMachineName(daemon), session: remoteChild ? session : nil, harness: nil)
        } else {
            record = AgentSessionRef(host: host ?? localHost, hostName: localHostName, session: session, harness: adopt?.harness)
        }
        let provisional = ProvisionalTab()
        let key = provisional.id, snapshot = provisional.conversation(ConversationTabRef(agentSession: record))
        let splitPane = split.map { ($0, ProvisionalPane(holding: snapshot)) }
        let sendsSplitID = daemon.supports(DaemonCapability.splitClientSplitID.rawValue)
        let store = daemon.store
        store.onTabCreated = { [weak self] provisional, tab in
            self?.tabCreated(provisional, as: AgentTabCreated(key: tab.id, surface: tab.surface))
        }
        let transaction = ClientTransactionID.generate()
        store.intend(splitPane.map { Intent.splitPane(pane: pane, direction: $0.0, ratio: 0.5, provisional: $0.1) } ?? .createTab(pane: pane, provisional: snapshot),
                     transaction: transaction)
        if let session { sessions[key] = session }
        newTabPages[key] = newTab
        if session == nil { seeds[key] = seed }
        if linked { linkedSessions.insert(key) }
        if let adopt { adoptions["\(adopt.harness):\(adopt.agentSessionId)"] = key }
        track(key, in: store)
        if let spare, let newTab { adoptSpare(spare, key: key, page: newTab.page) }
        let pending = AgentTabPending(key: key, surface: snapshot.surface)
        if remote { remoteCreations[key] = pending }
        pending.result = Task { [weak self, pending] () throws -> AgentTabCreated in
            do {
                guard let self else { throw CancellationError() }
                let (created, sequence) = try await create(pane, daemon, record, idempotencyKey, transaction,
                                                           splitPane.map { ConversationTabSplit(direction: $0.0, paneID: $0.1.paneID,
                                                                                          splitID: sendsSplitID ? $0.1.splitID : nil) })
                // Closed first (CancelledCreation): nothing moves to the store's tab, which the store
                // hides and closes; the page's view state goes.
                if !store.creations.wasCancelled(transaction) { tabCreated(key, as: created) }
                // The store's tab replaces the provisional one in one step, never beside it.
                ProvisionalTab.created(transaction, surface: created.surface, in: store)
                if let sequence { store.noteSettled(transaction, at: sequence) } else { store.noteSettledAtNextSnapshot(transaction) }
                if store.creations.wasCancelled(transaction) { throw CancellationError() }
                // A chat its page started (or the harness acpmux reported) before the store answered binds now.
                if let started = sessions[created.key], !remote { sendSession(started, for: created.key) }
                return created
            } catch {
                // A cancelled creation stays in the log until the store's close of its tab commits.
                if !(error is CancellationError) || !store.creations.wasCancelled(transaction) { store.rejectIntent(transaction) }
                self?.release(key)
                throw error
            }
        }
        return pending
    }

    /// Why a tab cannot open on the session host `host`, nil when it can: none, this Mac's own
    /// host, or this app's Chief home (`chief:<home id>`, a Chief subagent's tab), or in a pane of
    /// this Mac any other Chief home's, which is this Mac's too (#25262). Another
    /// machine's session never opens in a tab of this Mac (cx-k21v), and the refusal says so
    /// (`app_agent_open` with `host: "cmux16"` said only "see the app log", 2026-10-20). This
    /// Mac's host never opens in a pane of another machine (`daemonIsLocal` false) either.
    static func hostRefusal(_ host: String?, localHost: String?, chiefHost: String?, daemonIsLocal: Bool) -> String? {
        guard let host, host != chiefHost, !(daemonIsLocal && host.hasPrefix(ChiefHomeAcpmux.hostPrefix)) else { return nil }
        if host == localHost { return daemonIsLocal ? nil : RefusalStrings.agentTabMachineMismatch }
        return RefusalStrings.agentTabRunsOnHost(host)
    }

    /// ``open(in:of:session:seed:newTab:spare:linked:adopt:idempotencyKey:)`` in `pane`: the tab
    /// shows and is selected now (unless `select` is false); the store's tab keeps the selection
    /// when it replaces it, then `then` gets its id. A refusal is reported through the registry.
    /// Returns false when the pane cannot hold an agent tab.
    /// `hidden`: the tab never shows in `pane`'s strip (a chat bound for a new chat dock).
    @discardableResult
    func openTab(in pane: PaneController, session: String? = nil, seed: AgentPaneSeedSource? = nil,
                 newTab: (page: AgentPaneNewTab, handler: NewTabPageHandler)? = nil, spare: AgentPaneView? = nil,
                 linked: Bool = false, select: Bool = true, hidden: Bool = false, split: SplitDirection? = nil, focuses: Bool = true,
                 then: (@MainActor (String) -> Void)? = nil, failed: (@MainActor () -> Void)? = nil) -> Bool {
        let daemon = pane.daemon
        let pending: AgentTabPending
        do {
            pending = try open(in: pane.pane.handle, of: daemon, session: session, seed: seed, newTab: newTab,
                               spare: spare, linked: linked, split: split)
        } catch {
            pane.services.registry.refuse((error as? AgentTabRefusal)?.message ?? RefusalStrings.agentTabCreateFailed)
            return false
        }
        // A split's tab takes focus in its provisional pane now, then in the store's (as a terminal split does),
        // unless the caller keeps focus where it is (`focuses` false: a tab dropped on its own pane's edge).
        let content = split == nil || !focuses ? nil : pane.workspace, intent = content?.beginFocusIntent()
        content?.focus.expect(.tab(pending.key), generation: intent)
        // The selection follows the provisional tab to the created one (`moveSelection`).
        if select { pane.selectWhenReported(surface: pending.surface) }
        if hidden {
            pane.pendingDock.opened(pending.key)
            pane.apply(pane.snapshot())
        }
        pane.services.registry.track(Task {
            do {
                let created = try await pending.value()
                content?.expectFocus(on: created.surface, generation: intent)
                if hidden { pane.pendingDock.created(pending.key, as: created.key) }
                // A remote store can answer before its tree lists the provisional tab, so the
                // provisional selection never took: the store's tab is selected now (cx-k21v).
                if select, !hidden, !daemon.isLocal, pane.stripModel.selectedID?.rawValue != created.key {
                    pane.selectWhenReported(surface: created.surface)
                }
                then?(created.key)
                return nil
            } catch {
                // A chat bound for a dock that never came: the pane stops waiting for it (cx-ihyx2).
                if hidden { pane.dockFinished(pending.key) }
                failed?()
                guard !(error is CancellationError) else { return nil } // the person closed it first
                daemon.logger.error("new-conversation-tab (agent) failed: \(String(describing: error), privacy: .public)")
                return "\(RefusalStrings.agentTabCreateFailed)"
            }
        })
        return true
    }

    /// The store created provisional tab `key` as `created` (its reply, or the echo on the event
    /// that added it, whichever came first): view state and the selection move to it.
    func tabCreated(_ key: String, as created: AgentTabCreated) {
        rekey(key, to: created.key)
        moveSelection(key, created.surface)
    }

    /// The store answered the creation: view state under provisional `key` moves to `real`, and
    /// `key` keeps resolving to it until the provisional tab is gone.
    func rekey(_ key: String, to real: String) {
        guard key != real else { return }
        aliases[key] = real
        OutboundTab.rekeyed(key, to: real) // a tab on its way out of its pane stays out under its new id
        if remoteCreations[key] != nil || remoteSeeds[key] != nil { remoteAliases[key] = real }
        if let view = views.removeValue(forKey: key) {
            // A page made under the store's id meanwhile (another window) gives way to the one shown.
            if let other = views[real], other !== view { retirer.retire(other) }
            views[real] = view
        }
        if let value = sessions.removeValue(forKey: key) { sessions[real] = value }
        unsentDrafts.move(key, to: real)
        if let value = newTabPages.removeValue(forKey: key) { newTabPages[real] = value }
        if let value = seeds.removeValue(forKey: key) { seeds[real] = value }
        if let value = remoteSeeds.removeValue(forKey: key) { remoteSeeds[real] = value }
        if let value = remoteCreations.removeValue(forKey: key) { remoteCreations[real] = value }
        if let value = remoteStarts.removeValue(forKey: key) { remoteStarts[real] = value }
        if let value = pendingTurns.removeValue(forKey: key) { pendingTurns[real] = value }
        if let value = wakeStates.removeValue(forKey: key) { wakeStates[real] = value }
        if linkedSessions.remove(key) != nil { linkedSessions.insert(real) }
        adoptions = adoptions.mapValues { $0 == key ? real : $0 }
        if let store = tabStores.removeValue(forKey: key) { tabStores[real] = store }
        if checkpointFocusTab == key { checkpointFocusTab = real }
        // The provisional alias goes once the tree settles: live callbacks then name the store tab (conversion, project reads).
        if let view = views[real] { wire(view.model, key: real) }
        seenLive.remove(key)
    }

    /// Local tab `key` adopts the prewarmed `spare` as its page; the chat it becomes still opens tabs (cx-ckt2z).
    func adoptSpare(_ spare: AgentPaneView, key: String, page: AgentPaneNewTab) {
        standaloneViews.remove(spare)
        (views[key], spare.model.allowsTabConversion) = (spare, true)
        wire(spare.model, key: key)
        spare.adoptNewTab(page)
    }

    /// The page of tab `key` reported `session` (a new chat started, or the user changed the chat
    /// in this tab): a compare-and-swap from the session the tab shows, as a store intent
    /// (`Intent.bindAgentSession`): the record shows the new session at once, and a refusal (a
    /// change another device made first) removes it again with a reason.
    func sendSession(_ session: String, for key: String) {
        // Not created yet: the creation answer binds it (``open(in:of:session:seed:newTab:spare:linked:adopt:idempotencyKey:)``).
        // A chat of another machine: its daemon bound the session it started (cx-k21v).
        guard !ProvisionalTab.isProvisional(key), bindsHere(key) else { return }
        guard let record = lookup(key)?.record else {
            // The store answered but its tree does not list the tab yet: bind once it does.
            guard tabStores[key] != nil else { return }
            // task-owner: one wait for the tree to list a tab the store just created
            Task { [weak self] in
                for await listed in ObservationStream({ [weak self] in self?.lookup(key) != nil }) where listed {
                    self?.sendSession(session, for: key)
                    return
                }
            }
            return
        }
        // The record holds every pending bind: the next expects it. A new harness (acpmux's, cx-w4bbw) alone binds too.
        let (expected, harness) = (record.session, views[key]?.model.transport.sessions.harness(of: session))
        guard expected != session || (harness != nil && harness != record.harness), let store = lookup(key)?.store, let surface = store.tab(id: key)?.surface else { return }
        let transaction = ClientTransactionID.generate()
        store.intend(.bindAgentSession(surface: surface, session: session, harness: harness), transaction: transaction)
        // task-owner: one compare-and-swap; its answer settles or rejects the intent
        Task { [weak self] in
            let (outcome, sequence) = await self?.bind(key, surface, expected, session, harness) ?? (.failed, nil)
            switch outcome {
            case .taken:
                if let sequence { store.noteSettled(transaction, at: sequence) } else { store.noteSettledAtNextSnapshot(transaction) }
            case .conflict:
                store.rejectIntent(transaction)
                if expected != session { self?.actionRegistry?.refuse(RefusalStrings.agentTabSessionConflict) } // a harness alone: silent
            case .failed:
                store.rejectIntent(transaction)
                if expected != session { self?.actionRegistry?.refuse(RefusalStrings.agentTabSessionNotSaved) }
            }
        }
    }

    /// Whether tab `key`'s session is bound from this app: not for a chat of another machine,
    /// whose daemon binds the session it starts (cx-k21v).
    func bindsHere(_ key: String) -> Bool {
        remoteSeeds[key] == nil && remoteCreations[key] == nil
            && lookup(key)?.record.host.hasPrefix(AgentTabRemoteStart.registryPrefix) != true
    }

    /// The tab already resuming the outside chat `adopt` while a tree lists it.
    func tab(resuming adopt: AgentPaneAdopt) -> String? {
        guard let key = adoptions["\(adopt.harness):\(adopt.agentSessionId)"],
              let (record, store) = lookup(key), isAgentTab(key),
              case .connected = store.connectionState,
              record.host == localHost else { return nil }
        return key
    }

    /// "This chat runs on <machine>" for tab `key`, whose session another Mac's acpmux runs.
    func notice(for key: String) -> AgentTabElsewhereView? {
        let key = resolve(key)
        if let notice = notices[key] { return notice }
        guard let localHost, let (record, store) = lookup(key), record.host != localHost else { return nil }
        let notice = AgentTabElsewhereView(machine: record.hostName)
        notices[key] = notice
        track(key, in: store)
        return notice
    }

    /// A tab this client closed (``TabContentCache/release(_:)``). A tab the trees still list (the
    /// close failed, or its event has not arrived) keeps its page until its tree drops it.
    func releaseIfGone(_ key: String) {
        if lookup(resolve(key)) == nil { release(resolve(key)) }
    }

    /// Stops tab `key`'s page and forgets its view state.
    func release(_ key: String) {
        if let view = views.removeValue(forKey: key) {
            // An untouched new tab page goes back to the pool (no teardown, no rebuild, R81); a
            // page of another machine's chat never does (NewTabSparePool.recycle, cx-k21v).
            if newTabPages[key] != nil, recycle?(view) == true {
                standaloneViews.add(view)
            } else {
                retirer.retire(view)
            }
        }
        notices[key] = nil
        sessions[key] = nil
        newTabPages[key] = nil
        seeds[key] = nil
        remoteSeeds[key] = nil
        remoteCreations[key] = nil
        remoteStarts.removeValue(forKey: key)?.cancel()
        adoptions = adoptions.filter { $0.value != key }
        aliases = aliases.filter { $0.value != key }
        remoteAliases = remoteAliases.filter { $0.value != key && $0.key != key }
        linkedSessions.remove(key)
        pendingTurns[key] = nil
        wakeStates[key] = nil
        tabStores[key] = nil
        unsentDrafts.set("", for: key)
        launchImages.drop(key)
        seenLive.remove(key)
        forgetUnusedStores()
        stopCustomizationWhenUnused()
    }

    /// Lets go of the view state of tabs `store` listed and no longer lists, once it is connected
    /// with a live tree. While the daemon is away its tabs keep their views; a tab the tree has
    /// not listed yet (its creation just answered) is kept.
    func releaseGoneTabs(in store: DaemonStore) {
        guard store.liveTabListRevision != nil else { return }
        for (key, owner) in tabStores where owner === store {
            if store.liveTreeLists(tab: key) == true {
                seenLive.insert(key)
            } else if seenLive.contains(key) {
                release(key)
            }
        }
        aliases = aliases.filter { store.liveTreeLists(tab: $0.key) == true || !ProvisionalTab.isProvisional($0.key) }
    }

    /// Follows tab `key` in `store`'s tree, so its view state goes when the tree drops it.
    func track(_ key: String, in store: DaemonStore) {
        tabStores[key] = store
        if store.liveTreeLists(tab: key) == true { seenLive.insert(key) }
        let id = ObjectIdentifier(store)
        guard watches[id] == nil else { return }
        // task-owner: stored in watches; cancelled once no tab belongs to the store
        watches[id] = Task { [weak self] in
            for await revision in ObservationStream({ store.liveTabListRevision }) where revision != nil {
                guard let self else { return }
                self.releaseGoneTabs(in: store)
            }
        }
    }

    private func forgetUnusedStores() {
        let used = Set(tabStores.values.map { ObjectIdentifier($0) })
        for id in watches.keys where !used.contains(id) {
            watches.removeValue(forKey: id)?.cancel()
        }
    }
}

/// A new agent chat tab that shows now and that the store is still creating.
final class AgentTabPending {
    /// The provisional tab's id and surface (the tab the pane shows until the store answers).
    let key: String
    let surface: SurfaceID
    var result: Task<AgentTabCreated, any Error>?

    init(key: String, surface: SurfaceID) {
        self.key = key
        self.surface = surface
    }

    /// The store's tab, once created.
    func value() async throws -> AgentTabCreated {
        guard let result else { throw CancellationError() }
        return try await result.value
    }
}

/// A refusal to open an agent chat tab, with its localized reason.
struct AgentTabRefusal: Error {
    let message: String
}
