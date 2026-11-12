import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextHistoryDaemon
import Foundation

/// The daemon history module as the owner (`history-v1`, react-pages.md H3): page visits, the
/// location trail (cx-hnmbt.12), the merged read model and clearing go there; the app keeps only its
/// Back/Forward cursor (view state). The bundled daemon always serves it; while the local daemon
/// (re)connects, writes wait for it (`connectedDaemonHistory`).
extension HistoryService {
    /// The local daemon's history module while its link is up (the store's state: a connection outlives a drop) and serves `history-v1`.
    var daemonHistory: DaemonHistoryClient? {
        let daemon = services.machines.local
        guard case .connected = daemon.store.connectionState, let connection = daemon.connection, daemon.supports(DaemonHistoryClient.capability) else { return nil }
        return DaemonHistoryClient(connection: connection)
    }

    /// The local daemon's history module, once its link is up and it serves `history-v1` (``firstClient(_:)``).
    func connectedDaemonHistory() async -> DaemonHistoryClient? {
        await Self.firstClient { [weak self] in self?.daemonHistory }
    }

    /// The first client `read` gives: at once when it gives one already (an `ObservationStream`'s first `next()` evaluates
    /// now), else on the change that gives one, woken by that change, never by polling. nil only when the wait is cancelled.
    static func firstClient<Client: Sendable>(_ read: @escaping @MainActor @Sendable () -> Client?) async -> Client? {
        for await client in ObservationStream(read) { if let client { return client } }
        return nil
    }

    /// Entries from the local daemon (every kind but commands, closed items included; nil while its link is down: reported, not empty)
    /// merged with every connected machine's command rows. A daemon read is retried a few times; one that never answers is reported.
    func daemonEntries(_ query: HistoryQuery, _ daemon: DaemonHistoryClient?) async -> HistoryRead {
        let wantsCommands = query.kinds.isEmpty || query.kinds.contains(.command)
        // Commands are every connected daemon's terminal command rows (terminal-command-history-v1),
        // read by `commands`; the local daemon lists only its own.
        let appRead: Set<HistoryEntry.Kind> = [.command]
        let kinds = query.kinds.isEmpty ? Set(HistoryEntry.Kind.allCases).subtracting(appRead) : query.kinds.subtracting(appRead)
        var all: [HistoryEntry] = []
        var unavailable = false
        if !kinds.isEmpty {
            // Closed rows carry their chat's session and harness, and the daemon searches them (#31871).
            var rows: [DaemonHistoryEntry]?
            if let daemon { rows = await DaemonHistoryClient.retrying { try await daemon.list(kinds: kinds, text: query.text, range: query.range, limit: query.limit) }?.entries }
            all += (rows ?? []).compactMap { daemonRow($0) }.map { reachable($0) }
            unavailable = rows == nil
        }
        if wantsCommands {
            await commands.refresh()
            all += HistoryQuery(text: query.text, kinds: [.command], range: query.range).apply(to: commands.entries())
        }
        all.sort { ($0.time, $0.id) > ($1.time, $1.id) }
        if let limit = query.limit, all.count > limit { all.removeLast(all.count - limit) }
        return HistoryRead(entries: all, unavailable: unavailable)
    }

    /// One entry by id: commands from every connected machine's rows, everything else from the local daemon's newest entries of the
    /// id's kind (through the same bounded retry as a list read, so a slow daemon does not make the entry look gone; gone while it is away).
    /// An id that is not in a list that is not complete yet is `stillLoading`: one read, no wait for the rest.
    func daemonEntry(id: String, _ daemon: DaemonHistoryClient?) async -> HistoryLookup {
        if id.hasPrefix("command:") {
            await commands.refresh()
            return commands.entries().first { $0.id == id }.map { HistoryLookup.found($0) } ?? .gone
        }
        guard let daemon, let kind = id.split(separator: ":").first.flatMap({ HistoryEntry.Kind(rawValue: String($0)) }) else { return .gone }
        guard let list = await DaemonHistoryClient.retrying({ try await daemon.list(kinds: [kind], text: "", range: .all, limit: 5_000) }) else { return .gone }
        if let entry = list.entries.first(where: { $0.id == id }).flatMap({ daemonRow($0) }).map({ reachable($0) }) { return .found(entry) }
        return list.isStillLoading(id: id) ? .stillLoading : .gone
    }

    /// The app's entry for a daemon row, with the app's localized titles of an untitled terminal and chat.
    private func daemonRow(_ row: DaemonHistoryEntry) -> HistoryEntry? {
        row.historyEntry(untitled: Strings.untitledTerminal, untitledChat: AgentPaneModel.tabTitle)
    }

    /// A location row greyed while its tab is not reachable (the daemon cannot know).
    private func reachable(_ entry: HistoryEntry) -> HistoryEntry {
        entry.reachable { services.locationTrail.isAvailable($0) }
    }

    /// Queues a daemon mutation behind every earlier visit and mutation (``writes``; a clear made while it
    /// reconnects still happens, after them), then tells open pages (they also hear history-changed).
    func daemonMutation(_ body: @escaping HistoryWriteQueue<DaemonHistoryClient>.Write) {
        writes.enqueue(body) { [weak self] in self?.onChange?() }
    }

    /// Queues a clear from `since` to the click (`until`); one the local daemon cannot bound goes now or never (``HistoryWriteQueue/enqueueClear(live:_:_:done:)``).
    func daemonClear(kinds: Set<HistoryEntry.Kind>, since: Date?, until: Date, profile: String? = nil) {
        writes.enqueueClear(live: unboundedDaemonHistory, "history.clear", { try await $0.clear(kinds: kinds, since: since, until: until, profile: profile, unbounded: $2, key: $1) }) { [weak self] in self?.onChange?() }
    }

    /// The local daemon's history module while it is up and does not take a clear's click-time end (`history-clear-until-v1`).
    var unboundedDaemonHistory: DaemonHistoryClient? { services.machines.local.supports(DaemonHistoryClient.clearUntilCapability) ? nil : daemonHistory }

    /// Seeds a profile's omnibox from the daemon's visit summaries, after the daemon imported its older build's log (queued in
    /// ``writes`` ahead of every waiting write, so a clear made while the daemon was away still clears it). The read waits in
    /// ``writes`` behind every pending clear and remove, and reads again past one queued while it ran, so no cleared page comes back.
    func seedWhenConnected(_ history: InMemoryBrowserHistory, profile: BrowserProfileID) {
        let wireID = BrowserProfileRecord.wireID(for: profile)
        if let supportDirectory {
            writes.enqueue(ahead: true) { daemon, _ in
                try await daemon.importLegacyLog(LegacyHistoryFile.visitLogURL(profile: wireID, supportDirectory: supportDirectory),
                                                 supportDirectory: supportDirectory, profile: wireID)
            }
        }
        writes.read({ try await $0.summaries(profile: wireID) }, use: { [weak history] summaries in
            history?.merge(summaries.compactMap { summary in
                URL(string: summary.url).map {
                    BrowserHistoryEntry(url: $0, title: summary.title, visitCount: summary.visitCount,
                                        lastVisit: Date(timeIntervalSince1970: summary.lastVisitMS / 1_000))
                }
            })
        })
    }
}
