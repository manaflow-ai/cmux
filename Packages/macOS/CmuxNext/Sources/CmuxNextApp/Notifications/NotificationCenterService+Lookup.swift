import AppKit
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextBridge
import CmuxNextSettings
import CmuxNextFocus
import CmuxNextNotifications

/// Tab lookups, the dock badge and the pane attention marks.
extension NotificationCenterService {
    /// The workspace focus of `controller` that the person sees: nil while a top page (History,
    /// Settings, the App Store) covers the workspace, whose focus model still names the pane
    /// underneath. Every "viewed" and "typed into" rule reads this, never the raw focus model.
    static func shownFocus(_ c: WindowController) -> FocusState.Resolved? { c.shownTopPage == nil ? c.focus.state.resolved : nil }
    /// The tab `c` shows in its focused pane: its content's, or a loading pane's shown tab (an agent chat whose page is not up yet, cmux#42210).
    func viewedTab(_ c: WindowController) -> String? { guard let r = Self.shownFocus(c) else { return nil }; if case let .emptyPane(p) = r { return c.content?.paneModel(key: p).flatMap(shownTab(of:)) }; return r.tab }

    /// The content tab of the window whose focus owns `window` (a Chromium
    /// page window resolves to its cmux window).
    func focusedTab(in window: NSWindow?) -> String? {
        guard let services, let window = CmuxApplication.accessibilityWindow(for: window) else { return nil }
        return services.windows.controllers.first { $0.window === window }.flatMap(viewedTab)
    }

    /// `window`'s focus is a terminal (not a page, address bar, or find bar).
    func isTerminalFocused(in window: NSWindow?) -> Bool {
        guard let services, let window = CmuxApplication.accessibilityWindow(for: window),
              let controller = services.windows.controllers.first(where: { $0.window === window }),
              case .terminal? = Self.shownFocus(controller) else { return false }
        return true
    }

    /// The tab is the focused content of the key window while cmux is active.
    func isViewed(_ tabID: String) -> Bool {
        guard let services, services.appActiveSource() else { return false }
        return services.windows.controllers.contains { ownsKey($0) && viewedTab($0) == tabID }
    }
    /// `c`'s window is key, or a window it owns is: a Chromium page (an agent chat) takes the key from it (cmux#42210).
    func ownsKey(_ c: WindowController) -> Bool { _ = viewedRevision; return c.focus.state.windowKey || c.window?.holdsKeyboard(key: services?.keyWindowSource()) == true }

    static func tab(id: String, in store: DaemonStore) -> TabModel? { // perf-hot: 0.1ms key-dispatch (every key-down: noteTyping)
        // The store's index: every keystroke looks its tab up here (noteTyping), so no walk over every tab.
        store.tab(id: id)
    }

    func locate(surface: SurfaceID, in store: DaemonStore) -> LocatedTab? {
        guard let tab = store.tab(surface: surface), let pane = store.pane(containing: surface),
              let workspace = store.workspace(containing: pane.handle) else { return nil }
        return LocatedTab(tab: tab, pane: pane, workspace: workspace)
    }

    /// Each workspace adds its unread tab count, or 1 when that count is 0
    /// and the workspace is marked unread by hand: a mark adds nothing to a
    /// workspace that already has unread tabs (roughly the old app's count).
    /// Home's unread conversations (`homeUnread`, conversation ids) add one
    /// each, as Messages' Dock badge counts its unread; a conversation that a
    /// workspace tab shows with its own unread marker is already counted.
    /// The store keeps the counts per workspace (``DaemonStore/unreadTotals``): an observer of this
    /// count observes one value, never the tabs.
    static func unreadCount(_ store: DaemonStore?, homeUnread: [String] = []) -> Int {
        store?.unreadBadge(homeUnread: homeUnread) ?? Set(homeUnread).count
    }

    /// The badge count now: the store's unread tabs and Home's unread conversations.
    func currentUnreadCount() -> Int {
        let home = services?.home.unreadConversations ?? []
        return Self.unreadCount(services?.daemon.store, homeUnread: home.map(\.rawValue))
    }

    /// Sets the Dock tile's unread count (``DockBadge``: written only when it changes, and again
    /// when the Dock icon comes back).
    func updateDockBadge(_ count: Int) {
        dockAttention.unreadChanged(count)
        dockBadge.show(preferences.dockBadge && count > 0 ? String(count) : nil)
    }

    /// The handoff driver over the local daemon and this Mac's install
    /// principal (`feed.adopt` is an install-only owner op).
    func makeFeedDriver(_ services: AppServices, principal: FeedInstallPrincipal) -> FeedHandoffDriver {
        let feed = services.feed
        let daemon = services.daemon
        func connection() throws -> DaemonConnection {
            guard let connection = daemon.connection else { throw DaemonError.notConnected }
            return connection
        }
        return FeedHandoffDriver(
            daemon: .init(
                serves: { daemon.isLocal && daemon.identity?.supports(DaemonCapability.feedLocalOwner.rawValue) == true },
                list: { state, unread in
                    try await connection().request(FeedLocalListRequest(state: state, unread: unread ? true : nil)).items
                },
                begin: { try await connection().request(FeedLocalHandoffBeginRequest(item: $0)).item },
                done: { try await connection().request(FeedLocalHandoffDoneRequest(item: $0, home: $1)).item },
                abort: { try await connection().request(FeedLocalHandoffAbortRequest(item: $0)).item }),
            owner: { path, body in try await principal.call(path, body) },
            isSignedIn: { [weak feed] in feed?.isSignedIn ?? false },
            installID: { principal.installID },
            policy: { [weak self] in self?.feedHandoffPolicy() ?? FeedHandoffPolicy(preferences: .init(), mutedWorkspaces: []) },
            since: Self.handoffSince)
    }

    /// The first time the driver ran for `install` (ms), kept per Mac: open
    /// items from before it stay local, so nothing the removed step-1 bridge
    /// already posted is adopted a second time.
    static func handoffSince(_ install: String) -> UInt64 {
        let key = "feed.handoff.since.\(install)"
        if let stored = UserDefaults.standard.object(forKey: key) as? NSNumber { return stored.uint64Value }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        UserDefaults.standard.set(NSNumber(value: now), forKey: key)
        return now
    }

    /// The handoff rules under the current settings. Muted workspaces are
    /// matched by durable key and by public id (`ws_…`, an item's context).
    /// Only the workspaces in normal windows now (not `WindowManager.isIncognito`)
    /// hand off, matched by key, public id or terminal (#31210).
    func feedHandoffPolicy() -> FeedHandoffPolicy {
        var muted = preferences.mutedWorkspaces, normal = Set<String>()
        for workspace in services?.daemon.store.workspaces ?? [] {
            if muted.contains(workspace.id), let resource = workspace.resourceID { muted.insert(resource.rawValue) }
            guard services?.windows.isIncognito(workspace: workspace.id) == false else { continue }
            let terminals = workspace.screens.flatMap(\.panes).flatMap(\.tabs).compactMap { $0.terminalResourceID?.rawValue }
            normal.formUnion([workspace.id] + [workspace.resourceID?.rawValue].compactMap { $0 } + terminals)
        }
        // Classified once the windows restored (crash leftovers discarded, ephemeral flags awaited) and the flags are known.
        let classified = services.map { services in
            (services.windows.restored || services.windows.restoreGaveUp)
                && (services.daemon.connection?.mirrorsSessionState != true || services.daemon.store.session.known)
        } ?? true
        return FeedHandoffPolicy(preferences: preferences, mutedWorkspaces: muted, normalWindows: services == nil ? nil : normal,
                                 classified: classified)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Whether `workspace` is muted, and the key its sound rule is read under, on the machine that
    /// holds it (`machine`, else found by identity): a remote workspace's keys are qualified by
    /// machine, and a bare id an earlier build saved still counts (NotificationWorkspaceKey).
    func notificationKeys(of workspace: WorkspaceModel, machine: String? = nil) -> (muted: Bool, soundRule: String) {
        guard let services, let machine = machine
                ?? services.machines.daemons.first(where: { $0.store.workspace(id: workspace.id) === workspace })?.machineID else {
            return (preferences.mutedWorkspaces.contains(workspace.id), workspace.id)
        }
        let local = services.machines.local
        let localHolds = { (id: String) in local.store.workspace(id: id) != nil }
        let rules = preferences.sounds.workspaces
        return (preferences.workspaceMuted(machine: machine, workspace: workspace.id, localMachine: local.machineID, localHolds: localHolds),
                NotificationWorkspaceKey.ruleKey(machine: machine, workspace: workspace.id, localMachine: local.machineID,
                                                 hasRule: { rules[$0] != nil }, localHolds: localHolds))
    }

    /// Attention marks for `workspace`'s panes: every pane whose shown tab
    /// reads unread (``TabModel/showsUnread``: an unread notification or Mark
    /// as Unread, the value every unread dot reads; ``unreadRing(of:dismissed:)``),
    /// agent chats included, unless the workspace is muted or the style is `none`. As
    /// classic's ring lived on the notifying terminal, a pane showing a read
    /// tab (a Markdown file) draws none; the unread tab's dot marks it. The
    /// mark changes with the newest notification, so its animation restarts;
    /// its color is the notification source's override, if any.
    /// - Parameter shownTab: the tab id a window shows in the pane; nil
    ///   falls back to ``shownTab(of:)``.
    func attentionMarks(for workspace: WorkspaceModel,
                        shownTab: @MainActor (PaneModel) -> String? = { _ in nil }) -> [LayoutPaneID: AttentionMark] {
        let attention = DesignSettings.shared.attention
        let muted = notificationKeys(of: workspace).muted
        guard attention.style != .none, !muted else { return [:] }
        let key = highlightKey(for: workspace)
        var shown: [String: TabModel] = [:]
        var panes: [NotificationRings.ShownPane] = []
        for pane in workspace.screens.flatMap(\.panes) {
            guard let id = shownTab(pane) ?? self.shownTab(of: pane), let tab = pane.tabs.first(where: { $0.id == id }) else { continue }
            shown[pane.id] = tab
            panes.append(.init(pane: pane.id, tab: ringTab(tab, chatMachine: key.machine, finishes: tab.agentSession != nil, sight: true)))
        }
        var marks: [LayoutPaneID: AttentionMark] = [:]
        for mark in NotificationRings.marks(local: key.machine == MachineRegistry.localID, dismissed: dismissedHighlights[key] ?? 0,
                                            policy: ringPolicy(.focus), ringsTerminal: attention.rings(agentChat: false), panes: panes) {
            guard let generation = UInt64(mark.generation) else { continue }
            // A marked tab with no notification has no source: the ring's own color.
            let color = mark.color == "agent" ? preferences.sources[.agent]?.color
                : mark.color == "source" ? shown[mark.pane].flatMap { preferences.sources[source(of: $0)]?.color } : nil
            marks[LayoutPaneID(mark.pane)] = AttentionMark(color: color, generation: generation, agentChat: mark.agentChat, quiet: mark.quiet)
        }
        return marks
    }

    /// The generation of `tab`'s unread ring, or nil when it draws none: derived from the tab's
    /// unread state alone, so Mark as Unread rings and every read clears with no ring code of
    /// their own. An unread notification rings unless Dismiss Highlight hid it (`dismissed`, the
    /// workspace's newest dismissed notification id); a manual mark rings unless this mark was
    /// dismissed. A mark's generation sits above every notification id, so its ring restarts.
    func unreadRing(of tab: TabModel, dismissed: UInt64) -> UInt64? {
        guard tab.showsUnread else { return nil }
        return NotificationRings.ring(ringTab(tab, finishes: false), dismissed: dismissed)
    }

    /// A viewed tab reads its notifications and needs-you requests at once (cmux#42210), so it draws no ring (a mark stays). A tab a strip press holds is no look yet: it rings until the click's mouse-up blinks it out (cmux#46908).
    func readsOnSight(_ t: TabModel) -> Bool { NotificationRings.reads(.focus, ringTab(t, finishes: false, sight: true), turn: false, onSight: true, policy: ringPolicy(.focus)) }
    /// Going into `t`'s pane by `trigger` reads its ring: it clears every reason the ring draws for, an unread notification, a needs-you request, a mark (a click) and a finished turn (`turn`), by the policy.
    func reads(_ trigger: NotificationTrigger, _ t: TabModel, turn: Bool = false) -> Bool { NotificationRings.reads(trigger, ringTab(t, trigger, finishes: turn), turn: turn, onSight: false, policy: ringPolicy(trigger)) }
    /// The person went into ringing `pane` (a focus, a click) in the window they look at, its keys or a loading chat's page not attached yet: read it now (cmux#46908). A press on this pane reads it by its click, after a strip press holds it; one elsewhere (a sidebar row) is no look at it.
    func readOnEntry(_ pane: LayoutPaneID, click: Bool, in content: WorkspaceContentController) -> Bool {
        guard let services, services.appActiveSource(), click || NSApp?.currentEvent.map({ [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains($0.type) && clickedTab(in: $0.window, at: $0.locationInWindow)?.pane == pane }) != true,
              let window = services.windows.controllers.first(where: { $0.content === content }), window.shownTopPage == nil, ownsKey(window) || services.windows.active === window && services.keyWindowSource().map({ services.windows.owner(of: $0) == nil }) == true,
              let model = content.paneModel(key: pane.rawValue), let id = shownTab(of: model), !viewHolds.contains(id), let tab = model.tabs.first(where: { $0.id == id }), reads(click ? .click : .focus, tab, turn: true) else { return false }
        interacted(click ? .click : .focus, tab: tab); return true
    }
    /// Of the panes in `removed` (their mark just went away), those the person went into, focus included (cmux#42210: its
    /// ring is read on sight, maybe before `interacted(.focus)`): their ring blinks out. Forgets `workspace`'s entry reads.
    func takeEntryReads(removed: Set<LayoutPaneID>, in workspace: WorkspaceModel) -> Set<LayoutPaneID> {
        let flashes = DesignSettings.shared.attention.flashesOnEntry(.focus)
        guard !entryReads.isEmpty || !removed.isEmpty && flashes else { return [] }
        let all = workspace.screens.flatMap(\.panes)
        let panes = all.filter { removed.contains(LayoutPaneID($0.id)) }.map { NotificationRings.EntryPane(pane: $0.id, tabs: $0.tabs.map { ringTab($0, finishes: false, sight: true) }) }
        let entered = Set(NotificationRings.entered(removed: removed.map(\.rawValue), flashesOnFocus: flashes, anyEntryReads: !entryReads.isEmpty,
                                                    policy: ringPolicy(.focus), panes: panes).map { LayoutPaneID($0) })
        for tab in all.flatMap(\.tabs) { entryReads.remove(tab.id) }
        return entered
    }

    /// The tab `pane` shows: the selection of the window that shows it, else the daemon's default tab.
    func shownTab(of pane: PaneModel) -> String? {
        if let selected = services?.paneController(for: pane)?.stripModel.selectedID { return selected.rawValue }
        guard !pane.tabs.isEmpty else { return nil }
        return pane.tabs[min(max(pane.defaultTabIndex, 0), pane.tabs.count - 1)].id
    }

    /// Whether `workspace` draws an attention ring now (the Dismiss Highlight item shows only then).
    func hasHighlight(_ workspace: WorkspaceModel) -> Bool {
        !attentionMarks(for: workspace).isEmpty
    }

    func highlightKey(for workspace: WorkspaceModel) -> HighlightKey {
        let daemon = services?.machines.daemons.first { $0.store.workspace(id: workspace.id) === workspace }
        return HighlightKey(machine: daemon?.machineID ?? MachineRegistry.localID,
                            session: daemon?.identity?.session, id: workspace.id)
    }

    /// `t`'s facts under `trigger`, each read only where a rule can use it, so a tab no ring is drawn for observes no view
    /// state. `chatMachine`: the machine whose agent turns count as `t`'s (the marks read a thinking chat); `finishes`: a
    /// rule here reads its finished turn; `sight`: whether it is read on sight (the window walk of ``isViewed(_:)``).
    func ringTab(_ t: TabModel, _ trigger: NotificationTrigger = .focus, chatMachine: String? = nil, finishes: Bool = true, sight: Bool = false) -> NotificationRings.Tab {
        let key = t.markedUnread || t.attention != nil ? highlightKey(for: t) : nil
        let working = chatMachine.flatMap { machine in t.agentSession.map { AgentTurnStateStore.shared.isWorking($0, isChatMachine: { self.services?.machines.machineID(peer: $0) == machine }) } } ?? false
        return .init(t, trigger, dismissedMark: key.flatMap { t.markedUnread ? dismissedMarks[$0] : nil } ?? 0,
                     attentionHidden: key.map { t.attention != nil && ringHides.isHidden(t, owner: $0) } ?? false, working: working,
                     finished: finishes ? agentFinished[t.id] : nil, quiet: quietAgentFinishes.contains(t.id), viewed: sight && t.showsUnread && isViewed(t.id),
                     held: viewHolds.contains(t.id), entryRead: entryReads.contains(t.id),
                     clearsSource: t.hasUnread && NotificationPolicy(prefs: preferences).clears(trigger, for: source(of: t)))
    }

    func ringPolicy(_ trigger: NotificationTrigger) -> NotificationRings.Policy { .init(trigger, prefs: preferences) }

    func hideAttentionRing(of tab: TabModel) { ringHides.hide(tab, owner: highlightKey(for: tab)) }

    func highlightKey(for tab: TabModel) -> HighlightKey {
        let daemon = services?.machines.daemon(forTab: tab)
        return HighlightKey(machine: daemon?.machineID ?? MachineRegistry.localID,
                            session: daemon?.identity?.session, id: tab.id)
    }

    /// Dismiss Highlight (cx-epgo): reads `workspace` as classic's dismiss did (cmux#42210): every
    /// unread notification, manual mark and agent request goes, so the tab dot, the row dot and the
    /// Dock badge clear with the ring, and each ring blinks out. The hide below keeps a ring hidden
    /// where a daemon cannot take the read, until a newer notification or mark comes.
    func dismissHighlight(_ workspace: WorkspaceModel) {
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        let key = highlightKey(for: workspace)
        // A restarted daemon has new notification IDs; discard only that machine's old session.
        dismissedHighlights = dismissedHighlights.filter { $0.key.machine != key.machine || $0.key.session == key.session }
        dismissedMarks = dismissedMarks.filter { $0.key.machine != key.machine || $0.key.session == key.session }
        let plan = NotificationRings.dismissHighlight(local: key.machine == MachineRegistry.localID, flashesOnRead: DesignSettings.shared.attention.flashesOnRead,
                                                      dismissed: dismissedHighlights[key] ?? 0, tabs: tabs.map { ringTab($0) })
        // Hide first (a refused read must not bring the ring back), then read and blink.
        for step in plan.steps where tabs.indices.contains(step.index) {
            let tab = tabs[step.index]
            if step.clearsTurn { agentFinished[tab.id] = nil; quietAgentFinishes.remove(tab.id) }
            if let mark = step.hidesMark { dismissedMarks[highlightKey(for: tab)] = mark }
            if step.hidesAttention { hideAttentionRing(of: tab) }
            if step.entryRead { entryReads.insert(tab.id) }
            readDismissed(tab)
        }
        if workspace.markedUnread, let services { WorkspaceUnreadMark.set(false, on: [workspace], machines: services.machines) }
        if let newest = plan.through { dismissedHighlights[key] = newest; note("highlight dismissed workspace=\(workspace.id) through=\(newest)") }
    }

    /// Reads `tab` on its own daemon: its notification (a remote one only with notification-ack-v1), manual mark and agent request.
    private func readDismissed(_ tab: TabModel) { guard let daemon = owner(of: tab) ?? services?.daemon else { return }; if tab.hasUnread, daemon.isLocal || daemon.supports(DaemonCapability.notificationAck.rawValue) { acknowledge(tab, owner: daemon) }; if tab.markedUnread { try? TabUnreadMark.set(false, tab: tab, daemon: daemon) }; if tab.attention != nil { try? TabUnreadMark.clearAttention(tab: tab, daemon: daemon) } }
}
