import CmuxNextBrowser
import CryptoKit
import CmuxNextDaemon
import CmuxNextHistory
import Foundation

/// The daemon history module as the owner (`history-v1`, react-pages.md H3). When the local daemon
/// serves it, page visits, the merged read model and clearing go there; the app keeps the location
/// trail (client view state). Without it (an older daemon) the app-local paths stay; they are
/// deleted with the native History page (H4).
extension HistoryService {
    /// The local daemon's history module when it serves `history-v1`, else nil.
    var daemonHistory: DaemonHistoryClient? {
        let daemon = services.machines.local
        guard let connection = daemon.connection, daemon.supports(DaemonHistoryClient.capability) else { return nil }
        return DaemonHistoryClient(connection: connection)
    }

    /// Entries from the daemon (every kind but locations) merged with the app's own trail.
    func daemonEntries(_ query: HistoryQuery, _ daemon: DaemonHistoryClient) async -> [HistoryEntry] {
        let wantsLocations = query.kinds.isEmpty || query.kinds.contains(.location)
        let kinds = query.kinds.isEmpty ? Set(HistoryEntry.Kind.allCases).subtracting([.location]) : query.kinds.subtracting([.location])
        var all: [HistoryEntry] = []
        if !kinds.isEmpty {
            let rows = (try? await daemon.list(kinds: kinds, text: query.text, range: query.range, limit: query.limit)) ?? []
            all = rows.compactMap { $0.historyEntry() }
        }
        if wantsLocations { all += HistoryQuery(text: query.text, kinds: [.location], range: query.range).apply(to: locationEntries()) }
        all.sort { ($0.time, $0.id) > ($1.time, $1.id) }
        if let limit = query.limit, all.count > limit { all.removeLast(all.count - limit) }
        return all
    }

    /// One entry by id: locations from the app's trail, everything else from the daemon's newest
    /// entries of the id's kind.
    func daemonEntry(id: String, _ daemon: DaemonHistoryClient) async -> HistoryEntry? {
        if id.hasPrefix("location:") { return locationEntries().first { $0.id == id } }
        guard let kind = id.split(separator: ":").first.flatMap({ HistoryEntry.Kind(rawValue: String($0)) }) else { return nil }
        let rows = (try? await daemon.list(kinds: [kind], text: "", range: .all, limit: 5_000)) ?? []
        return rows.first { $0.id == id }?.historyEntry()
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

    /// Seeds a profile's omnibox from the daemon's visit summaries, after the daemon took over the
    /// profile's app-local log from before it owned page history (`legacyLog`).
    func seedFromDaemon(_ history: InMemoryBrowserHistory, profile: BrowserProfileID, _ daemon: DaemonHistoryClient) {
        let wireID = BrowserProfileRecord.wireID(for: profile)
        let legacy = supportDirectory.map { BrowserVisitLog.fileURL(profile: wireID, supportDirectory: $0) }
        // task-owner: one-shot import and read of the profile's visit summaries
        Task { [weak history] in
            if let legacy { await Self.handOver(legacy, profile: wireID, to: daemon) }
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
    static func handOver(_ log: URL, profile: String, to daemon: DaemonHistoryClient) async {
        let files = FileManager.default
        guard let attributes = try? files.attributesOfItem(atPath: log.path) else { return }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data(log.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let key = "cmux-next-history-import-\(digest)-\(size)-\(Int64(modified * 1_000))"
        guard (try? await daemon.importVisits(profile: profile, path: log.path, key: key)) != nil else { return }
        for suffix in ["", "-wal", "-shm"] where files.fileExists(atPath: log.path + suffix) {
            try? files.removeItem(atPath: log.path + suffix)
        }
    }
}

/// A profile's omnibox history persistence: the daemon's visit store when it serves `history-v1`,
/// else the app-local log (`BrowserVisitSink`). Decided per write, so a daemon that connects later
/// takes over without a relaunch. Daemon writes go through one FIFO, so a title never overtakes the
/// visit it names.
final class RoutingVisitSink: BrowserHistoryPersistence {
    let local: BrowserVisitSink
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

    deinit {
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
        guard let daemon = daemon() else { return local.didRemoveEntry(for: url) }
        let profile = profile, text = url.absoluteString
        continuation.yield { try? await daemon.removeVisits(profile: profile, url: text) }
    }
}
