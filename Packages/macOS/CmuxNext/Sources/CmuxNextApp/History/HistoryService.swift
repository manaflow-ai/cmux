import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextSettings
import Foundation

/// The read-side merge of every history owner (plans/cmux-next/history.md
/// 2): page visits per browser profile, the location trail, closed tabs,
/// agent sessions. Feeds the history page, the palette pages and
/// `history.list`. Owns the per-profile visit logs; never a second copy of
/// a fact another owner keeps.
final class HistoryService {
    unowned let services: AppServices
    /// `<Application Support>/<bundle id>`, set at launch; nil keeps page
    /// history in memory only (tests).
    var supportDirectory: URL?
    private var sinks: [BrowserProfileID: BrowserVisitSink] = [:]
    /// The omnibox persistence per profile: the daemon when it serves `history-v1`, else `sinks`.
    private var routes: [BrowserProfileID: RoutingVisitSink] = [:]
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

    /// Launch: page history becomes durable in `supportDirectory`.
    func start(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
        let cache = services.cache
        attach(cache.history, profile: .default)
        for (profile, entry) in cache.profileHistories { attach(entry.history, profile: profile) }
        cache.onProfileHistoryCreated = { [weak self] profile, history in self?.attach(history, profile: profile) }
        cache.onProfileHistoryDropped = { [weak self] profile in self?.forget(profile: profile) }
        adoptDaemonHistoryOnFirstConnection()
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

    /// Makes `history` (a profile's omnibar history) durable and seeds it
    /// from the profile's log.
    func attach(_ history: InMemoryBrowserHistory, profile: BrowserProfileID) {
        let sink = sink(for: profile)
        let route = routes[profile] ?? RoutingVisitSink(local: sink, profile: BrowserProfileRecord.wireID(for: profile)) { [weak self] in
            self?.daemonHistory
        }
        routes[profile] = route
        route.onRemove = { [weak self, wire = BrowserProfileRecord.wireID(for: profile)] url in
            guard let sync = self?.services.onboarding.historySync else { return }
            Task { await sync.forgetPage(url, profile: wire) }  // task-owner: imported pages too
        }
        history.persistence = route
        if let daemon = daemonHistory { return seedFromDaemon(history, profile: profile, daemon) }
        let log = sink.log
        // task-owner: one-shot launch read of the profile's visit log
        Task { [weak history] in
            _ = await log.prune()
            let summaries = await log.summaries()
            let entries = summaries.compactMap { summary in
                URL(string: summary.url).map { BrowserHistoryEntry(url: $0, title: summary.title, visitCount: summary.visitCount, lastVisit: summary.lastVisit) }
            }
            history?.merge(entries)
        }
    }

    private func sink(for profile: BrowserProfileID) -> BrowserVisitSink {
        if let existing = sinks[profile] { return existing }
        let url = supportDirectory.map {
            BrowserVisitLog.fileURL(profile: BrowserProfileRecord.wireID(for: profile), supportDirectory: $0)
        }
        let sink = BrowserVisitSink(log: BrowserVisitLog(url: url))
        sinks[profile] = sink
        return sink
    }

    /// Drains writes routed to the app-local log before daemon handoff.
    func flushLocalHistory(profile: BrowserProfileID) async -> Bool {
        guard let sink = sinks[profile] else { return true }
        return await sink.flush()
    }

    /// Every profile's log: the default one first.
    private var profileLogs: [(profile: String, log: BrowserVisitLog)] {
        var profiles: [BrowserProfileID] = [.default]
        profiles += services.browserProfiles.ordered.map(\.engineProfile).filter { $0 != .default }
        return profiles.map { (BrowserProfileRecord.wireID(for: $0), sink(for: $0).log) }
    }

    // MARK: Entries

    /// Every entry matching `query`, newest first.
    func entries(_ query: HistoryQuery) async -> [HistoryEntry] {
        if let daemon = daemonHistory { return await daemonEntries(query, daemon) }
        let wants = { (kind: HistoryEntry.Kind) in query.kinds.isEmpty || query.kinds.contains(kind) }
        var all: [HistoryEntry] = []
        if wants(.location) { all += locationEntries() }
        if wants(.closed) { all += closedEntries() }
        if wants(.agent) {
            await agents.refresh()
            all += agents.entries()
        }
        if wants(.command) {
            await commands.refresh()
            all += commands.entries()
        }
        if wants(.page) {
            let since = query.range.start(now: Date())
            let limit = query.limit ?? 500
            for (profile, log) in profileLogs {
                for visit in await log.visits(matching: query.text, since: since, limit: limit) {
                    all.append(HistoryEntry(id: "page:\(profile):\(visit.id)", kind: .page, time: visit.time,
                                            title: visit.title.flatMap { $0.isEmpty ? nil : $0 } ?? visit.url, detail: visit.url,
                                            payload: .page(url: visit.url, profile: profile)))
                }
            }
        }
        return query.apply(to: all)
    }

    /// The entry with `id` among every owner's current entries, or nil when it is gone.
    func entry(id: String) async -> HistoryEntry? {
        if let daemon = daemonHistory { return await daemonEntry(id: id, daemon) }
        return await entries(HistoryQuery(limit: 5_000)).first { $0.id == id }
    }

    func locationEntries() -> [HistoryEntry] {
        let trail = services.locationTrail
        return trail.trail.entries.enumerated().map { index, entry in
            let location = entry.location
            return HistoryEntry(
                id: "location:\(location.key.machine):\(location.key.tab):\(index)", kind: .location, time: entry.enteredAt,
                title: location.title, detail: location.workspaceTitle, machineName: location.machineName,
                isAvailable: trail.isAvailable(location), payload: .location(location, isCurrent: index == trail.trail.cursor))
        }
    }

    /// Closed tabs, screens and workspaces, as the daemons record them
    /// (`closed-history-v2`): the only closed history (reopen-closed.md 9). Newest first, a page
    /// closed again once (``DaemonClosedHistory/newestOnce(_:_:)``).
    func closedEntries() -> [HistoryEntry] {
        let shown = DaemonClosedHistory.entries(DaemonClosedHistory.allKinds, in: services).filter { Self.isWorthReopening($0.item) }
        return DaemonClosedHistory.newestOnce(shown) { ($0.item, $0.daemon.machineID) }.map { entry in
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

    /// Clears `kinds` (empty: all) in `range`. Pages clear in every profile.
    func clear(kinds: Set<HistoryEntry.Kind>, range: HistoryRange) {
        let wants = { (kind: HistoryEntry.Kind) in kinds.isEmpty || kinds.contains(kind) }
        let since = range.start(now: Date())
        if wants(.page) { Task { [sync = services.onboarding.historySync] in await sync.forget(profile: nil, since: since) } }  // task-owner: imported pages too
        if daemonHistory != nil {
            // The daemon removes page visits and trail entries and hides agents; terminal commands
            // are deleted as rows in each connected daemon. The app's Back/Forward steps drop too.
            let appOwned: Set<HistoryEntry.Kind> = [.command]
            let owned = kinds.isEmpty ? Set(HistoryEntry.Kind.allCases).subtracting(appOwned) : kinds.subtracting(appOwned)
            if !owned.isEmpty { daemonMutation { try await $0.clear(kinds: owned, range: range) } }
            if wants(.command) { commands.delete(since: since) }
            if wants(.page) {
                for profile in [BrowserProfileID.default] + services.browserProfiles.ordered.map(\.engineProfile) {
                    services.cache.history(for: profile).forget(since: since)
                }
            }
            if wants(.location) { services.locationTrail.clear(since: since) }
            onChange?()
            return
        }
        if wants(.page) {
            for (profile, _) in profileLogs {
                guard let engine = BrowserProfileRecord.engineProfile(for: profile) else { continue }
                sink(for: engine).clear(since: since)
                services.cache.history(for: engine).forget(since: since)
            }
        }
        if wants(.location) { services.locationTrail.clear(since: since) }
        if wants(.closed) { DaemonClosedHistory.clear(since: since, services: services) }
        if wants(.agent) { agents.hide(since: since) }
        if wants(.command) { commands.delete(since: since) }
        onChange?()
    }

    /// Clears one profile's page history (Clear Browser History).
    func clearPages(profile: BrowserProfileID, range: HistoryRange) {
        let since = range.start(now: Date())
        Task { [sync = services.onboarding.historySync, wire = BrowserProfileRecord.wireID(for: profile)] in await sync.forget(profile: wire, since: since) }  // task-owner: imported pages too
        if daemonHistory != nil {
            let wireID = BrowserProfileRecord.wireID(for: profile)
            daemonMutation { try await $0.clear(kinds: [.page], range: range, profile: wireID) }
            services.cache.history(for: profile).forget(since: since)
            onChange?()
            return
        }
        sink(for: profile).clear(since: since)
        services.cache.history(for: profile).forget(since: since)
        onChange?()
    }

    /// Removes one entry (the page's Remove from History).
    func remove(_ entry: HistoryEntry) {
        // Pages keep the app path: the omnibox removes the URL and its persistence (the daemon when
        // it serves history-v1) removes every visit of it.
        if daemonHistory != nil, entry.kind != .page, entry.kind != .command {
            let id = entry.id
            daemonMutation { try await $0.remove(ids: [id]) }
            // The daemon removes every trail entry of the place; so do the app's Back/Forward steps.
            if case .location(let location, _) = entry.payload { services.locationTrail.remove(location.key) }
            onChange?()
            return
        }
        switch entry.payload {
        case .page(let url, let profile):
            let engine = BrowserProfileRecord.engineProfile(for: profile) ?? .default
            if let url = URL(string: url) { services.cache.history(for: engine).removeEntry(for: url) }
        case .location(let location, _):
            services.locationTrail.remove(location.key)
        case .closed(let item):
            // Delete Permanently on the daemon that owns it.
            guard let id = DaemonClosedHistory.daemonID(fromHistoryID: item.id),
                  let entry = DaemonClosedHistory.entry(id, in: services) else { break }
            DaemonClosedHistory.delete(entry, services: services)
        case .agent(let session):
            agents.hide(session)
        case .command(let command):
            commands.delete(command)
        }
        onChange?()
    }

    /// Removes every page visit of `host` in every profile.
    func removePages(host: String) {
        Task { [sync = services.onboarding.historySync] in await sync.forgetSite(host: host) }  // task-owner: imported pages too
        if daemonHistory != nil {
            // One site removal on the daemon (one backup); memory forgets without persistence.
            daemonMutation { try await $0.removeSite(host: host, profile: nil) }
            for profile in [BrowserProfileID.default] + services.browserProfiles.ordered.map(\.engineProfile) {
                services.cache.history(for: profile).forget(host: host)
            }
            onChange?()
            return
        }
        for (profile, _) in profileLogs {
            guard let engine = BrowserProfileRecord.engineProfile(for: profile) else { continue }
            // One removal in the log; memory forgets without persistence (not a Remove from History per page).
            sink(for: engine).remove(host: host)
            services.cache.history(for: engine).forget(host: host)
        }
        onChange?()
    }

    /// A deleted browser profile: its page history goes too, on the daemon and in the app-local log.
    func forget(profile: BrowserProfileID) {
        if daemonHistory != nil {
            let wireID = BrowserProfileRecord.wireID(for: profile)
            daemonMutation { try await $0.clear(kinds: [.page], range: .all, profile: wireID) }
        }
        sinks[profile]?.clear(since: nil)
        sinks[profile] = nil
    }
}
