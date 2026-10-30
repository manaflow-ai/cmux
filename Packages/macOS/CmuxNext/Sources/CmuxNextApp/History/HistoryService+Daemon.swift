import CmuxNextBrowser
import CryptoKit
import CmuxNextDaemon
import CmuxNextHistory
import Foundation

/// The daemon history module as the owner (`history-v1`, react-pages.md H3). When the local daemon
/// serves it, page visits, the location trail (cx-hnmbt.12), the merged read model and clearing go
/// there; the app keeps only its Back/Forward cursor (view state). Without it (an older daemon) the
/// app-local paths stay; they are deleted with the native History page (H4).
extension HistoryService {
    /// The local daemon's history module when it serves `history-v1`, else nil.
    var daemonHistory: DaemonHistoryClient? {
        let daemon = services.machines.local
        guard let connection = daemon.connection, daemon.supports(DaemonHistoryClient.capability) else { return nil }
        return DaemonHistoryClient(connection: connection)
    }

    /// Entries from the daemon (every kind but commands) merged with every machine's command rows.
    func daemonEntries(_ query: HistoryQuery, _ daemon: DaemonHistoryClient) async -> [HistoryEntry] {
        let wantsCommands = query.kinds.isEmpty || query.kinds.contains(.command)
        // Commands are every connected daemon's terminal command rows (terminal-command-history-v1),
        // read by `commands`; the local daemon lists only its own.
        let appRead: Set<HistoryEntry.Kind> = [.command]
        let kinds = query.kinds.isEmpty ? Set(HistoryEntry.Kind.allCases).subtracting(appRead) : query.kinds.subtracting(appRead)
        var all: [HistoryEntry] = []
        if !kinds.isEmpty {
            let rows = (try? await daemon.list(kinds: kinds, text: query.text, range: query.range, limit: query.limit)) ?? []
            all = rows.compactMap { $0.historyEntry(untitled: Strings.untitledTerminal) }.map { reachable($0) }
        }
        if wantsCommands {
            await commands.refresh()
            all += HistoryQuery(text: query.text, kinds: [.command], range: query.range).apply(to: commands.entries())
        }
        all.sort { ($0.time, $0.id) > ($1.time, $1.id) }
        if let limit = query.limit, all.count > limit { all.removeLast(all.count - limit) }
        return all
    }

    /// One entry by id: commands from every machine's rows, everything else from the daemon's newest
    /// entries of the id's kind.
    func daemonEntry(id: String, _ daemon: DaemonHistoryClient) async -> HistoryEntry? {
        if id.hasPrefix("command:") {
            await commands.refresh()
            return commands.entries().first { $0.id == id }
        }
        guard let kind = id.split(separator: ":").first.flatMap({ HistoryEntry.Kind(rawValue: String($0)) }) else { return nil }
        let rows = (try? await daemon.list(kinds: [kind], text: "", range: .all, limit: 5_000)) ?? []
        return rows.first { $0.id == id }?.historyEntry(untitled: Strings.untitledTerminal).map { reachable($0) }
    }

    /// A location row greyed while its tab is not reachable (the daemon cannot know).
    private func reachable(_ entry: HistoryEntry) -> HistoryEntry {
        entry.reachable { services.locationTrail.isAvailable($0) }
    }

    /// Runs a daemon mutation off the caller, then tells open pages (they also hear history-changed).
    func daemonMutation(_ body: @escaping @Sendable (DaemonHistoryClient) async throws -> Void) {
        guard let daemon = daemonHistory else { return }
        // task-owner: one history mutation; ends with its reply
        Task { [weak self] in
            try? await body(daemon)
            self?.onChange?()
        }
    }

    /// The local daemon usually connects after launch attached the profiles, so `attach` read the
    /// app-local logs. On the first connection, a daemon that serves `history-v1` takes over every
    /// attached profile: it imports the profile's old log and seeds the omnibox from its store.
    func adoptDaemonHistoryOnFirstConnection() {
        let local = services.machines.local
        // task-owner: one wait for the local daemon's first connection; ends with it or a failed startup
        Task { [weak self, weak local] in
            if let local, local.connection == nil { await local.firstConnection() }
            guard let self, let daemon = self.daemonHistory else { return }
            let cache = self.services.cache
            self.seedFromDaemon(cache.history, profile: .default, daemon)
            for (profile, entry) in cache.profileHistories { self.seedFromDaemon(entry.history, profile: profile, daemon) }
        }
    }

    /// Seeds a profile's omnibox from the daemon's visit summaries, after the daemon took over the
    /// profile's app-local log from before it owned page history (`legacyLog`).
    func seedFromDaemon(_ history: InMemoryBrowserHistory, profile: BrowserProfileID, _ daemon: DaemonHistoryClient) {
        let wireID = BrowserProfileRecord.wireID(for: profile)
        let legacy = supportDirectory.map { BrowserVisitLog.fileURL(profile: wireID, supportDirectory: $0) }
        let supportDirectory = supportDirectory
        // task-owner: one-shot import and read of the profile's visit summaries
        Task { [weak self, weak history] in
            guard let self else { return }
            let flushed = await self.flushLocalHistory(profile: profile)
            if flushed, let legacy, let supportDirectory {
                await Self.handOver(legacy, supportDirectory: supportDirectory, profile: wireID, to: daemon)
            }
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

/// A profile's omnibox history persistence: the daemon's visit store when it serves `history-v1`,
/// else the app-local log (`BrowserVisitSink`). Decided per write, so a daemon that connects later
/// takes over without a relaunch. Daemon writes go through one FIFO, so a title never overtakes the
/// visit it names.
final class RoutingVisitSink: BrowserHistoryPersistence {
    let local: BrowserVisitSink
    /// A page removed from the history (Remove from History, Shift-Delete in the omnibar): the
    /// import store drops its imported copy too, so it does not come back at the next launch.
    var onRemove: ((URL) -> Void)?
    private let profile: String
    private let daemon: () -> DaemonHistoryClient?
    private let continuation: AsyncStream<@Sendable () async -> Void>.Continuation
    private let drain: Task<Void, Never>

    init(local: BrowserVisitSink, profile: String, daemon: @escaping () -> DaemonHistoryClient?) {
        self.local = local
        self.profile = profile
        self.daemon = daemon
        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream(bufferingPolicy: .bufferingNewest(4_096))
        self.continuation = continuation
        // task-owner: the sink's lifetime; ends when the stream finishes in deinit
        drain = Task.detached {
            for await write in stream { await write() }
        }
    }

    nonisolated deinit {
        continuation.finish()
    }

    func didRecordVisit(url: URL, title: String?, at date: Date) {
        guard let daemon = daemon() else { return local.didRecordVisit(url: url, title: title, at: date) }
        let profile = profile, text = url.absoluteString
        continuation.yield { try? await daemon.recordVisit(profile: profile, url: text, title: title, tab: nil, at: date) }
    }

    func didUpdateTitle(_ title: String, for url: URL) {
        guard let daemon = daemon() else { return local.didUpdateTitle(title, for: url) }
        let profile = profile, text = url.absoluteString
        continuation.yield { try? await daemon.updateTitle(profile: profile, url: text, title: title) }
    }

    func didRemoveEntry(for url: URL) {
        onRemove?(url)
        guard let daemon = daemon() else { return local.didRemoveEntry(for: url) }
        let profile = profile, text = url.absoluteString
        continuation.yield { try? await daemon.removeVisits(profile: profile, url: text) }
    }
}
