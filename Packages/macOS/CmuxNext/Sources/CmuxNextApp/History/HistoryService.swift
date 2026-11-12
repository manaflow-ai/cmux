import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextHistoryDaemon
import CmuxNextHistoryPages
import CmuxNextSettings
import Foundation

/// The read-side merge of every history owner (plans/cmux-next/history.md
/// 2): page visits per browser profile, the location trail, closed tabs,
/// agent sessions. Feeds the history page, the palette pages and
/// `history.list`. The daemon history module (`history-v1`) owns page visits,
/// the location trail, agent hides and closed items; never a second copy of a
/// fact another owner keeps.
final class HistoryService {
    unowned let services: AppServices
    /// `<Application Support>/<bundle id>`, set at launch: where an older build's visit logs wait for the
    /// daemon's import. nil in tests.
    var supportDirectory: URL?
    let pages = NSHashTable<HistoryCookieBackupsPageProvider>.weakObjects() // The open History pages (their shown rows).
    /// The omnibox persistence per profile: the daemon's visit store (`DaemonVisitSink`).
    private var routes: [BrowserProfileID: DaemonVisitSink] = [:]
    /// Every daemon history write in order, visits, clears and removes alike, held while the local daemon is away.
    private(set) lazy var writes = HistoryWriteQueue<DaemonHistoryClient>(retryable: DaemonHistoryClient.isLinkDrop) { [weak self] in await self?.connectedDaemonHistory() }
    let hidden: HiddenHistoryStore
    let agents: AgentHistory
    let commands: CommandHistory
    let closedRetention: ClosedHistoryRetention
    /// Tabs this process made a page for (a later page for the same tab is
    /// a reload, not a visit).
    var installedPageKeys: Set<String> = []
    /// Called after an owner changed (open history pages refresh).
    var onChange: (() -> Void)?

    init(services: AppServices) {
        self.services = services
        hidden = HiddenHistoryStore(services: services)
        agents = AgentHistory(services: services, hidden: hidden)
        commands = CommandHistory(services: services)
        closedRetention = ClosedHistoryRetention(services: services)
    }

    /// Launch: every profile's omnibox history persists through the daemon.
    func start(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
        let cache = services.cache
        attach(cache.history, profile: .default)
        for (profile, entry) in cache.profileHistories { attach(entry.history, profile: profile) }
        cache.onProfileHistoryCreated = { [weak self] profile, history in self?.attach(history, profile: profile) }
        cache.onProfileHistoryDropped = { [weak self] profile in self?.forget(profile: profile) }
        // Folders of closed workspaces deleted while the app was not running (the CLI, another app).
        DaemonClosedHistory.emptyAgentHomeTrash()
    }

    /// Launch: keeps each daemon's command recording and closed-history
    /// retention in step with the settings.
    func startDaemonSync(settings: SettingsController) {
        commands.start(settings: settings)
        closedRetention.start(settings: settings)
    }

    // MARK: Pages

    /// Makes `history` (a profile's omnibar history) durable on the daemon and seeds it from the
    /// daemon's visit summaries once the local daemon serves `history-v1`.
    func attach(_ history: InMemoryBrowserHistory, profile: BrowserProfileID) {
        let route = routes[profile] ?? DaemonVisitSink(profile: BrowserProfileRecord.wireID(for: profile), writes: writes)
        routes[profile] = route
        route.onRemove = { [weak self, wire = BrowserProfileRecord.wireID(for: profile)] url in
            guard let sync = self?.services.onboarding.historySync else { return }
            Task { await sync.forgetPage(url, profile: wire) }  // task-owner: imported pages too
        }
        history.persistence = route
        seedWhenConnected(history, profile: profile)
    }

    // MARK: Entries

    /// Every entry matching `query`, newest first.
    func entries(_ query: HistoryQuery) async -> [HistoryEntry] { await read(query).entries }

    /// Same, with whether an owner did not answer (an empty list is then not "nothing there").
    func read(_ query: HistoryQuery) async -> HistoryRead {
        // The local daemon may be (re)connecting: its kinds are then unavailable, every connected daemon's commands still list.
        await daemonEntries(query, daemonHistory)
    }

    /// The entry with `id`: one the History page shows, else among every owner's current entries, or nil when it is gone.
    func entry(id: String) async -> HistoryEntry? {
        if case .found(let entry) = await lookup(id: id) { return entry }
        return nil
    }

    /// Same, and whether an entry that was not found is only not listed yet (its kind's entries are not complete).
    func lookup(id: String) async -> HistoryLookup {
        if let shown = pages.allObjects.lazy.compactMap({ $0.shown[id] }).first { return .found(shown) }
        return await daemonEntry(id: id, daemonHistory)
    }

    /// Closed tabs, screens and workspaces, as the daemons record them
    /// (`closed-history-v2`): the only closed history (reopen-closed.md 9). Newest first, a page
    /// closed again once (``DaemonClosedHistory/newestOnce(_:_:)``).
    /// `limit`: only the newest that many are named (the titlebar list).
    func closedEntries(limit: Int? = nil) -> [HistoryEntry] {
        let shown = DaemonClosedHistory.entries(DaemonClosedHistory.allKinds, in: services).filter { Self.isWorthReopening($0.item) }
        let once = DaemonClosedHistory.newestOnce(shown) { ($0.item, $0.daemon.machineID) }
        return once.prefix(limit ?? once.count).map { entry in
            let item = entry.item, tab = Self.shownTab(item)
            let kind = Self.closedKind(item)
            let (title, detail) = Self.daemonClosedText(item, pages: services.pages)
            let closed = CmuxNextHistory.ClosedItem(id: DaemonClosedHistory.historyID(item.id), kind: kind, title: title,
                                                    machine: entry.daemon.machineID, cwd: tab?.cwd,
                                                    url: tab?.page == nil ? Self.realText(tab?.url) : nil,
                                                    agentSession: Self.closedAgentSession(item))
            let local = entry.daemon.machineID == MachineRegistry.localID
            return HistoryEntry(id: "closed:daemon:\(item.id)", kind: .closed,
                                time: Date(timeIntervalSince1970: Double(item.closedAtMs) / 1000), title: title,
                                detail: detail, machineName: local ? nil : entry.daemon.machineID,
                                payload: .closed(closed))
        }
    }

    static func closedKind(_ item: CmuxNextDaemon.ClosedItem) -> CmuxNextHistory.ClosedItem.Kind {
        switch item.kind {
        case .tab:
            switch shownTab(item)?.kind {
            case "conversation": .conversationTab
            case "browser": .browserTab
            default: .terminalTab
            }
        case .screen: .screen
        case .workspace, .window: .workspace
        }
    }

    /// A closed tab can be an agent chat. A screen or workspace remains its container kind,
    /// even when the first tab it would reopen is an agent chat.
    static func closedAgentSession(_ item: CmuxNextDaemon.ClosedItem) -> CmuxNextHistory.ClosedItem.AgentSession? {
        guard item.kind == .tab, let agent = shownTab(item)?.agentSession else { return nil }
        return .init(sessionID: agent.session, harness: agent.harness)
    }

    /// Whether reopening `item` gives something back (Leo 2026-10-11: Recently Closed was full of
    /// "workspace-35 about:blank" rows). A group or a window always does; a tab, screen or
    /// workspace only with a tab that is not ``isBlank(_:)``.
    static func isWorthReopening(_ item: CmuxNextDaemon.ClosedItem) -> Bool {
        item.group != nil || item.kind == .window || item.tabs.contains { !isBlank($0) }
    }

    /// An untouched New Tab page or a browser on `about:blank`, as the daemon marks it (`empty`).
    /// A closed chat with no title yet or a remote terminal looks the same otherwise, and reopens.
    static func isBlank(_ tab: CmuxNextDaemon.ClosedItem.Tab) -> Bool { tab.empty }

    /// A closed name or address worth showing: a chat or New Tab page is kept as a browser tab on
    /// `about:blank` (a tab item carries that as its name too), never a name or an address.
    static func realText(_ text: String?) -> String? {
        text.flatMap { $0.isEmpty || $0 == "about:blank" ? nil : $0 }
    }

    /// The tab an item is named by: its first real one, past any New Tab page beside it.
    static func shownTab(_ item: CmuxNextDaemon.ClosedItem) -> CmuxNextDaemon.ClosedItem.Tab? {
        item.tabs.first { !isBlank($0) } ?? item.tabs.first
    }

    /// A daemon closed item's title and detail line. A page tab (a diff,
    /// Settings) is named by its page and has no address to show: its
    /// `url` is the `about:blank` placeholder (cx-h7y9).
    static func daemonClosedText(_ item: CmuxNextDaemon.ClosedItem, pages: InternalPageTabStore) -> (title: String, detail: String?) {
        let tab = shownTab(item)
        let page = tab?.page.map { pages.provider(InternalPageID(rawValue: $0))?.title ?? $0 }
        let url = realText(tab?.url)
        // The closed record deliberately omits the agent's host. Without trustworthy source
        // identity, a local daemon tree is not proof that its chat belongs to this app's acpmux.
        let agentTitle = closedAgentSession(item) == nil ? nil : AgentPaneModel.tabTitle
        let title = item.group.map { WorkspaceGroupUndo.historyTitle($0.name) }
            ?? realText(item.name) ?? realText(tab?.name) ?? page ?? agentTitle ?? url ?? tab?.cwd ?? Strings.untitledTerminal
        return (title, page == nil ? url ?? tab?.cwd : nil)
    }

    // MARK: Clearing

    /// Clears `kinds` (empty: all) in `range`, from its start to the click (the daemon clear may wait in `writes`). Pages clear in every profile.
    func clear(kinds: Set<HistoryEntry.Kind>, range: HistoryRange) {
        let wants = { (kind: HistoryEntry.Kind) in kinds.isEmpty || kinds.contains(kind) }
        let now = Date(), since = range.start(now: now)
        if wants(.page) { Task { [sync = services.onboarding.historySync] in await sync.forget(profile: nil, since: since) } }  // task-owner: imported pages too
        // The daemon removes page visits, trail entries and closed items and hides agents; terminal
        // commands are deleted as rows in each connected daemon. The app's Back/Forward steps drop too.
        let appOwned: Set<HistoryEntry.Kind> = [.command]
        let owned = kinds.isEmpty ? Set(HistoryEntry.Kind.allCases).subtracting(appOwned) : kinds.subtracting(appOwned)
        if !owned.isEmpty { daemonClear(kinds: owned, since: since, until: now) }
        if owned.contains(.agent) { hidden.hideLocally { $0.hide(since: since, now: now, kind: "agent") } }
        if wants(.command) { commands.delete(since: since, until: now) }
        if wants(.page) {
            for profile in [BrowserProfileID.default] + services.browserProfiles.ordered.map(\.engineProfile) {
                services.cache.history(for: profile).forget(since: since)
            }
        }
        if wants(.location) { services.locationTrail.clear(since: since) }
        onChange?()
    }

    /// Clears one profile's page history (Clear Browser History).
    func clearPages(profile: BrowserProfileID, range: HistoryRange) {
        let now = Date(), since = range.start(now: now)
        let wireID = BrowserProfileRecord.wireID(for: profile)
        Task { [sync = services.onboarding.historySync] in await sync.forget(profile: wireID, since: since) }  // task-owner: imported pages too
        daemonClear(kinds: [.page], since: since, until: now, profile: wireID)
        services.cache.history(for: profile).forget(since: since)
        onChange?()
    }

    /// Removes one entry (the page's Remove from History).
    func remove(_ entry: HistoryEntry) {
        switch entry.payload {
        case .page(let url, let profile):
            // The omnibox removes the URL and its persistence removes every visit of it on the daemon.
            let engine = BrowserProfileRecord.engineProfile(for: profile) ?? .default
            if let url = URL(string: url) { services.cache.history(for: engine).removeEntry(for: url) }
        case .command(let command):
            commands.delete(command)
        case .location, .closed, .agent:
            let id = entry.id
            daemonMutation { try await $0.remove(ids: [id], key: $1) }
            if case .agent(let session) = entry.payload { hidden.hideLocally { $0.hide(entry: session.qualifiedID) } }
            // The daemon removes every trail entry of the place; so do the app's Back/Forward steps.
            if case .location(let location, _) = entry.payload { services.locationTrail.remove(location.key) }
        }
        onChange?()
    }

    /// Removes every page visit of `host` in every profile.
    func removePages(host: String) {
        Task { [sync = services.onboarding.historySync] in await sync.forgetSite(host: host) }  // task-owner: imported pages too
        // One site removal on the daemon (one backup); memory forgets without persistence.
        daemonMutation { try await $0.removeSite(host: host, profile: nil, key: $1) }
        for profile in [BrowserProfileID.default] + services.browserProfiles.ordered.map(\.engineProfile) {
            services.cache.history(for: profile).forget(host: host)
        }
        onChange?()
    }

    /// A deleted browser profile: its page history goes too, on the daemon.
    func forget(profile: BrowserProfileID) {
        let wireID = BrowserProfileRecord.wireID(for: profile), now = Date()
        daemonClear(kinds: [.page], since: nil, until: now, profile: wireID)
        routes[profile] = nil
    }
}

