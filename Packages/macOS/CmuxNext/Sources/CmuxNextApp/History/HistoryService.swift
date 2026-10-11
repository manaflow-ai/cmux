import CmuxNextBrowser
import CmuxNextHistory
import Foundation

/// The read-side merge of every history owner (plans/cmux-next/history.md
/// 2): page visits per browser profile, the location trail, closed tabs,
/// agent sessions. Feeds the history page, the palette pages and
/// `history.list`. Owns the per-profile visit logs; never a second copy of
/// a fact another owner keeps.
final class HistoryService {
    private unowned let services: AppServices
    /// `<Application Support>/<bundle id>`, set at launch; nil keeps page
    /// history in memory only (tests).
    var supportDirectory: URL?
    private var sinks: [BrowserProfileID: BrowserVisitSink] = [:]
    let hidden: HiddenHistoryStore
    let agents: AgentHistory
    let commands: CommandHistory
    /// Tabs this process made a page for (a later page for the same tab is
    /// a reload, not a visit).
    var installedPageKeys: Set<String> = []
    /// Called after an owner changed (open history pages refresh).
    var onChange: (() -> Void)?

    init(services: AppServices) {
        self.services = services
        hidden = HiddenHistoryStore(services: services)
        agents = AgentHistory(services: services, hidden: hidden)
        commands = CommandHistory(services: services, hidden: hidden)
    }

    /// Launch: page history becomes durable in `supportDirectory`.
    func start(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
        let cache = services.cache
        attach(cache.history, profile: .default)
        for (profile, entry) in cache.profileHistories { attach(entry.history, profile: profile) }
        cache.onProfileHistoryCreated = { [weak self] profile, history in self?.attach(history, profile: profile) }
        cache.onProfileHistoryDropped = { [weak self] profile in self?.forget(profile: profile) }
    }

    // MARK: Pages

    /// Makes `history` (a profile's omnibar history) durable and seeds it
    /// from the profile's log.
    func attach(_ history: InMemoryBrowserHistory, profile: BrowserProfileID) {
        let sink = sink(for: profile)
        history.persistence = sink
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

    /// Every profile's log: the default one first.
    private var profileLogs: [(profile: String, log: BrowserVisitLog)] {
        var profiles: [BrowserProfileID] = [.default]
        profiles += services.browserProfiles.ordered.map(\.engineProfile).filter { $0 != .default }
        return profiles.map { (BrowserProfileRecord.wireID(for: $0), sink(for: $0).log) }
    }

    // MARK: Entries

    /// Every entry matching `query`, newest first.
    func entries(_ query: HistoryQuery) async -> [HistoryEntry] {
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
        await entries(HistoryQuery(limit: 5_000)).first { $0.id == id }
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
    /// (`closed-history-v2`): the only closed history (reopen-closed.md 9).
    func closedEntries() -> [HistoryEntry] {
        DaemonClosedHistory.entries([.tab, .screen, .workspace], in: services).map { entry in
            let item = entry.item, tab = item.tabs.first
            let kind: CmuxNextHistory.ClosedItem.Kind = switch item.kind {
            case .tab: tab?.kind == "browser" ? .browserTab : .terminalTab
            case .screen: .screen
            case .workspace: .workspace
            }
            let title = item.group.map { WorkspaceGroupUndo.historyTitle($0.name) }
                ?? item.name ?? tab?.name ?? tab?.url ?? tab?.cwd ?? Strings.untitledTerminal
            let closed = CmuxNextHistory.ClosedItem(id: DaemonClosedHistory.historyID(item.id), kind: kind, title: title,
                                                    machine: entry.daemon.machineID, cwd: tab?.cwd, url: tab?.url)
            let local = entry.daemon.machineID == MachineRegistry.localID
            return HistoryEntry(id: "closed:daemon:\(item.id)", kind: .closed,
                                time: Date(timeIntervalSince1970: Double(item.closedAtMs) / 1000), title: title,
                                detail: tab?.url ?? tab?.cwd, machineName: local ? nil : entry.daemon.machineID,
                                payload: .closed(closed))
        }
    }

    // MARK: Clearing

    /// Clears `kinds` (empty: all) in `range`. Pages clear in every profile.
    func clear(kinds: Set<HistoryEntry.Kind>, range: HistoryRange) {
        let wants = { (kind: HistoryEntry.Kind) in kinds.isEmpty || kinds.contains(kind) }
        let since = range.start(now: Date())
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
        if wants(.command) { commands.hide(since: since) }
        onChange?()
    }

    /// Clears one profile's page history (Clear Browser History).
    func clearPages(profile: BrowserProfileID, range: HistoryRange) {
        let since = range.start(now: Date())
        sink(for: profile).clear(since: since)
        services.cache.history(for: profile).forget(since: since)
        onChange?()
    }

    /// Removes one entry (the page's Remove from History).
    func remove(_ entry: HistoryEntry) {
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
            commands.hide(command)
        }
        onChange?()
    }

    /// Removes every page visit of `host` in every profile.
    func removePages(host: String) {
        for (profile, _) in profileLogs {
            guard let engine = BrowserProfileRecord.engineProfile(for: profile) else { continue }
            sink(for: engine).remove(host: host)
            let memory = services.cache.history(for: engine)
            for entry in memory.entries where entry.url.host()?.lowercased() == host.lowercased() { memory.removeEntry(for: entry.url) }
        }
        onChange?()
    }

    /// A deleted browser profile: its log file goes too.
    func forget(profile: BrowserProfileID) {
        sinks[profile]?.clear(since: nil)
        sinks[profile] = nil
    }
}
