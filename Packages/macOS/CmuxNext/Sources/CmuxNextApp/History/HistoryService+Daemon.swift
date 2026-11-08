import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextCompat
import CryptoKit
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

    /// The local daemon's history module, once its link is up and it serves `history-v1`: woken by the
    /// connection itself, never by polling. nil only when the waiting task is cancelled.
    func connectedDaemonHistory() async -> DaemonHistoryClient? {
        for await _ in ObservationStream({ [weak self] in self?.daemonHistory != nil }) {
            if let daemon = daemonHistory { return daemon }
        }
        return nil
    }

    /// Entries from the daemon (every kind but commands, closed items included) merged with every machine's command rows.
    /// A daemon read is retried a few times; one that never answers is reported, not empty.
    func daemonEntries(_ query: HistoryQuery, _ daemon: DaemonHistoryClient) async -> HistoryRead {
        let wantsCommands = query.kinds.isEmpty || query.kinds.contains(.command)
        // Commands are every connected daemon's terminal command rows (terminal-command-history-v1),
        // read by `commands`; the local daemon lists only its own.
        let appRead: Set<HistoryEntry.Kind> = [.command]
        let kinds = query.kinds.isEmpty ? Set(HistoryEntry.Kind.allCases).subtracting(appRead) : query.kinds.subtracting(appRead)
        var all: [HistoryEntry] = []
        var unavailable = false
        if !kinds.isEmpty {
            // Closed rows carry their chat's session and harness, and the daemon searches them (#31871).
            let rows = await DaemonHistoryClient.retrying { try await daemon.list(kinds: kinds, text: query.text, range: query.range, limit: query.limit) }
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

    /// One entry by id: commands from every machine's rows, everything else from the daemon's newest entries of the id's kind
    /// (through the same bounded retry as a list read, so a slow daemon does not make the entry look gone).
    func daemonEntry(id: String, _ daemon: DaemonHistoryClient) async -> HistoryEntry? {
        if id.hasPrefix("command:") {
            await commands.refresh()
            return commands.entries().first { $0.id == id }
        }
        guard let kind = id.split(separator: ":").first.flatMap({ HistoryEntry.Kind(rawValue: String($0)) }) else { return nil }
        let rows = await DaemonHistoryClient.retrying { try await daemon.list(kinds: [kind], text: "", range: .all, limit: 5_000) } ?? []
        return rows.first(where: { $0.id == id }).flatMap { daemonRow($0) }.map { reachable($0) }
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
    func daemonMutation(_ body: @escaping @Sendable (DaemonHistoryClient) async throws -> Void) {
        writes.enqueue(body) { [weak self] in self?.onChange?() }
    }

    /// Seeds a profile's omnibox from the daemon's visit summaries once the local daemon serves
    /// history, after the daemon imported the profile's app-local log from an older build. The import
    /// goes in ``writes`` ahead of every waiting write, so a clear made before the daemon came back (or
    /// one whose own profile walk attached this profile) reaches the daemon after it and clears it too.
    func seedWhenConnected(_ history: InMemoryBrowserHistory, profile: BrowserProfileID) {
        let wireID = BrowserProfileRecord.wireID(for: profile)
        let seed: @MainActor () -> Void = { [weak self, weak history] in
            // task-owner: one wait for the local daemon, then a one-shot read of the profile's visit summaries
            Task {
                guard let daemon = await self?.connectedDaemonHistory() else { return }
                let summaries = (try? await daemon.summaries(profile: wireID)) ?? []
                let entries = summaries.compactMap { summary in
                    URL(string: summary.url).map {
                        BrowserHistoryEntry(url: $0, title: summary.title, visitCount: summary.visitCount,
                                            lastVisit: Date(timeIntervalSince1970: summary.lastVisitMS / 1_000))
                    }
                }
                history?.merge(entries)
            }
        }
        guard let supportDirectory else {
            seed()
            return
        }
        let legacy = LegacyHistoryFile.visitLogURL(profile: wireID, supportDirectory: supportDirectory)
        writes.enqueue(ahead: true, { await Self.handOver(legacy, supportDirectory: supportDirectory, profile: wireID, to: $0) }, done: seed)
    }

    /// Imports `log` (an app-local `History.sqlite`) into the daemon's store of `profile`, then
    /// deletes it and its SQLite side files once the daemon confirms the import committed. A failed
    /// import leaves the file for the next launch; the key (path, size, time) makes a retry of the
    /// same file replay, and the daemon also records each imported file, so no session imports it
    /// twice.
    static func handOver(_ log: URL, supportDirectory: URL, profile: String, to daemon: DaemonHistoryClient) async {
        guard let source = LegacyHistoryFile(url: log, supportDirectory: supportDirectory) else { return }
        let sidecarURLs = ["-wal", "-shm"].map {
            URL(fileURLWithPath: source.url.path + $0)
        }
        var sidecars: [LegacyHistoryFile] = []
        var missing: [URL] = []
        for url in sidecarURLs {
            if LegacyHistoryFile.pathEntryExists(url) {
                guard let file = LegacyHistoryFile(url: url, supportDirectory: supportDirectory) else { return }
                sidecars.append(file)
            } else {
                missing.append(url)
            }
        }
        let captured = [source] + sidecars
        let identity = captured.map { "\($0.url.path)|\($0.fingerprint)" }
            + missing.map { "\($0.path)|missing" }
        let digest = SHA256.hash(data: Data(identity.joined(separator: "\n").utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let key = "cmux-next-history-import-\(digest)"
        guard (try? await daemon.importVisits(profile: profile, path: source.url.path, key: key)) != nil else { return }
        _ = LegacyHistoryFile.removeGenerationIfUnchanged(
            Array(sidecars.reversed()) + [source],
            missing: missing
        )
    }
}
