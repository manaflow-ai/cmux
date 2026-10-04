import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// Opening agent chat tabs on the workspace store with zero wait, and letting their view state
/// go when the store drops them (cmux-tui/spec/commands.md, new-conversation-tab).
extension AgentTabStore {
    /// The `origin` of the app's `new-conversation-tab` requests for agent chats.
    static let createOrigin = "cmux-next-agent-tab"

    /// Adds a new agent chat tab to `pane`'s strip. The tab shows at once (R81): a create intent
    /// on the store's log shows a provisional tab until the store's tab replaces it; a refusal
    /// removes it again. View state (seed, new tab page, spare page, link) is kept under the
    /// provisional id and moves to the store's id when the creation answers.
    ///
    /// - Parameters:
    ///   - pane: The pane (its daemon handle).
    ///   - daemon: The daemon that owns the pane.
    ///   - session: The acpmux session it shows; nil starts a new chat.
    ///   - seed: What a new chat inherits (cwd, a draft); ignored with a session.
    ///   - newTab: Shows the new tab page until it becomes a chat; the
    ///     handler gets the terminal or browser choices and shortcut edits.
    ///   - spare: A prewarmed page (``makeSpare(_:)``) the new tab page adopts.
    ///   - linked: A `cmux://session/<id>` link opened it: its page refuses a session the
    ///     daemon does not have instead of falling back.
    ///   - adopt: The outside chat it resumes (`harness:agentSessionId`).
    ///   - idempotencyKey: The creation's key; a retry with it returns the same tab. Fresh by default.
    /// - Throws: ``AgentTabRefusal`` when the pane cannot hold one (nothing is shown).
    func open(in pane: PaneID, of daemon: DaemonService, session: String? = nil, seed: AgentPaneSeedSource? = nil,
              newTab: (page: AgentPaneNewTab, handler: NewTabPageHandler)? = nil, spare: AgentPaneView? = nil,
              linked: Bool = false, adopt: AgentPaneAdopt? = nil,
              idempotencyKey: String = UUID().uuidString.lowercased()) throws -> AgentTabPending {
        guard let localHost, holdsTabs(daemon), reachable(daemon) else {
            if let spare, recycle?(spare) != true { retirer.retire(spare) }
            throw AgentTabRefusal(message: reachable(daemon) ? RefusalStrings.agentTabsUnsupported : RefusalStrings.agentTabsDisconnected)
        }
        let record = AgentSessionRef(host: localHost, hostName: localHostName, session: session, harness: adopt?.harness)
        let key = ProvisionalTab.id()
        var snapshot = TabSnapshot(surface: ProvisionalTab.surface(), tabResourceID: ResourceID(rawValue: key),
                                   kind: .conversation, title: "about:blank", browserRenderer: "frontend")
        snapshot.conversation = ConversationTabRef(agentSession: record)
        let store = daemon.store
        let transaction = ClientTransactionID.generate()
        store.intend(.createTab(pane: pane, provisional: snapshot), transaction: transaction)
        if let session { sessions[key] = session }
        newTabPages[key] = newTab
        if session == nil { seeds[key] = seed }
        if linked { linkedSessions.insert(key) }
        if let adopt { adoptions["\(adopt.harness):\(adopt.agentSessionId)"] = key }
        track(key, in: store)
        if let spare, let newTab {
            standaloneViews.remove(spare)
            wire(spare.model, key: key)
            views[key] = spare
            spare.adoptNewTab(newTab.page)
        }
        let pending = AgentTabPending(key: key, surface: snapshot.surface)
        pending.result = Task { [weak self, pending] () throws -> AgentTabCreated in
            do {
                guard let self else { throw CancellationError() }
                let (created, sequence) = try await create(pane, daemon, record, idempotencyKey)
                rekey(key, to: created.key)
                pending.onCreated?(created)
                // The store's tab replaces the provisional one in one step, never beside it.
                ProvisionalTab.created(transaction, surface: created.surface, in: store)
                if let sequence { store.noteSettled(transaction, at: sequence) } else { store.noteSettledAtNextSnapshot(transaction) }
                if let close = pendingCloses.removeValue(forKey: key) {
                    close(created.key)
                } else if let started = sessions[created.key], started != session {
                    // A chat its page started before the store answered binds now.
                    sendSession(started, for: created.key)
                }
                return created
            } catch {
                store.rejectIntent(transaction)
                self?.release(key)
                throw error
            }
        }
        return pending
    }

    /// ``open(in:of:session:seed:newTab:spare:linked:adopt:idempotencyKey:)`` in `pane`: the tab
    /// shows and is selected now (unless `select` is false); the store's tab keeps the selection
    /// when it replaces it, then `then` gets its id. A refusal is reported through the registry.
    /// Returns false when the pane cannot hold an agent tab.
    @discardableResult
    func openTab(in pane: PaneController, session: String? = nil, seed: AgentPaneSeedSource? = nil,
                 newTab: (page: AgentPaneNewTab, handler: NewTabPageHandler)? = nil, spare: AgentPaneView? = nil,
                 linked: Bool = false, select: Bool = true, then: (@MainActor (String) -> Void)? = nil) -> Bool {
        let daemon = pane.daemon
        let pending: AgentTabPending
        do {
            pending = try open(in: pane.pane.handle, of: daemon, session: session, seed: seed, newTab: newTab,
                               spare: spare, linked: linked)
        } catch {
            pane.services.registry.refuse((error as? AgentTabRefusal)?.message ?? RefusalStrings.agentTabCreateFailed)
            return false
        }
        if select { pane.selectWhenReported(surface: pending.surface) }
        let provisional = pending.key
        pending.onCreated = { [weak pane] created in
            guard select, let pane, pane.stripModel.selectedID?.rawValue == provisional else { return }
            pane.selectWhenReported(surface: created.surface)
        }
        pane.services.registry.track(Task {
            do {
                let created = try await pending.value()
                then?(created.key)
                return nil
            } catch {
                daemon.logger.error("new-conversation-tab (agent) failed: \(String(describing: error), privacy: .public)")
                return "\(RefusalStrings.agentTabCreateFailed)"
            }
        })
        return true
    }

    /// The store answered the creation: view state under provisional `key` moves to `real`, and
    /// `key` keeps resolving to it until the provisional tab is gone.
    func rekey(_ key: String, to real: String) {
        guard key != real else { return }
        aliases[key] = real
        if let view = views.removeValue(forKey: key) {
            // A page made under the store's id meanwhile (another window) gives way to the one shown.
            if let other = views[real], other !== view { retirer.retire(other) }
            views[real] = view
        }
        if let value = sessions.removeValue(forKey: key) { sessions[real] = value }
        if let value = newTabPages.removeValue(forKey: key) { newTabPages[real] = value }
        if let value = seeds.removeValue(forKey: key) { seeds[real] = value }
        if let value = pendingTurns.removeValue(forKey: key) { pendingTurns[real] = value }
        if let value = sentSessions.removeValue(forKey: key) { sentSessions[real] = value }
        if linkedSessions.remove(key) != nil { linkedSessions.insert(real) }
        adoptions = adoptions.mapValues { $0 == key ? real : $0 }
        if let store = tabStores.removeValue(forKey: key) { tabStores[real] = store }
        if checkpointFocusTab == key { checkpointFocusTab = real }
        seenLive.remove(key)
    }

    /// The page of tab `key` reported `session` (a new chat started, or the user changed the chat
    /// in this tab): a compare-and-swap from the session the store last had. A session changed
    /// elsewhere meanwhile is refused with a reason; the next change expects the store's.
    func sendSession(_ session: String, for key: String) {
        // Not created yet: the creation answer binds it (``open(in:of:session:seed:newTab:spare:linked:adopt:idempotencyKey:)``).
        guard !ProvisionalTab.isProvisional(key) else { return }
        guard let record = lookup(key)?.record else {
            // The store answered but its tree does not list the tab yet: bind once it does.
            guard tabStores[key] != nil else { return }
            // task-owner: one wait for the tree to list a tab the store just created
            Task { [weak self] in
                for await listed in Observations({ [weak self] in self?.lookup(key) != nil }) where listed {
                    self?.sendSession(session, for: key)
                    return
                }
            }
            return
        }
        // A sent session the store now shows is settled.
        if let sent = sentSessions[key], record.session == sent { sentSessions[key] = nil }
        let expected = sentSessions[key] ?? record.session
        guard expected != session else { return }
        sentSessions[key] = session
        bind(key, expected, session) { [weak self] outcome in
            guard let self, sentSessions[key] == session else { return }
            switch outcome {
            case .taken:
                break // kept until the store's record shows it, so the next change expects it
            case .conflict:
                sentSessions[key] = nil
                actionRegistry?.refuse(RefusalStrings.agentTabSessionConflict)
            case .failed:
                sentSessions[key] = nil
                actionRegistry?.refuse(RefusalStrings.agentTabSessionNotSaved)
            }
        }
    }

    /// Close on a tab the store is still creating: it closes when the store answers (its
    /// provisional surface names no daemon tab). False for any other tab.
    func closeWhenCreated(_ key: String, close: @escaping @MainActor (String) -> Void) -> Bool {
        guard ProvisionalTab.isProvisional(key), aliases[key] == nil, tabStores[key] != nil else { return false }
        pendingCloses[key] = close
        return true
    }

    /// The tab already resuming the outside chat `adopt` while a tree lists it.
    func tab(resuming adopt: AgentPaneAdopt) -> String? {
        guard let key = adoptions["\(adopt.harness):\(adopt.agentSessionId)"], isAgentTab(key) else { return nil }
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
            // An untouched new tab page goes back to the pool (no teardown, no rebuild, R81).
            if newTabPages[key] != nil, recycle?(view) == true {
                standaloneViews.add(view)
            } else {
                retirer.retire(view)
            }
        }
        notices[key] = nil
        pendingCloses[key] = nil
        sessions[key] = nil
        sentSessions[key] = nil
        newTabPages[key] = nil
        seeds[key] = nil
        adoptions = adoptions.filter { $0.value != key }
        aliases = aliases.filter { $0.value != key }
        linkedSessions.remove(key)
        pendingTurns[key] = nil
        tabStores[key] = nil
        seenLive.remove(key)
        forgetUnusedStores()
        stopCustomizationWhenUnused()
    }

    /// Lets go of the view state of tabs `store` listed and no longer lists, once it is connected
    /// with a live tree. While the daemon is away its tabs keep their views; a tab the tree has
    /// not listed yet (its creation just answered) is kept.
    func releaseGoneTabs(in store: DaemonStore) {
        guard let live = Self.liveTabs(store) else { return }
        for (key, owner) in tabStores where owner === store {
            if live.contains(key) {
                seenLive.insert(key)
            } else if seenLive.contains(key) {
                release(key)
            }
        }
        aliases = aliases.filter { live.contains($0.key) || !ProvisionalTab.isProvisional($0.key) }
    }

    static func liveTabs(_ store: DaemonStore) -> Set<String>? {
        guard case .connected = store.connectionState, store.isLoaded else { return nil }
        return Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
    }

    /// Follows tab `key` in `store`'s tree, so its view state goes when the tree drops it.
    func track(_ key: String, in store: DaemonStore) {
        tabStores[key] = store
        if Self.liveTabs(store)?.contains(key) == true { seenLive.insert(key) }
        let id = ObjectIdentifier(store)
        guard watches[id] == nil else { return }
        // task-owner: stored in watches; cancelled once no tab belongs to the store
        watches[id] = Task { [weak self] in
            for await live in Observations({ Self.liveTabs(store) }) where live != nil {
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
    /// Runs when the store answered, before its tab replaces the provisional one.
    var onCreated: (@MainActor (AgentTabCreated) -> Void)?
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
