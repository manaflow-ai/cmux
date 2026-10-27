public import Foundation
import CmuxNextCompat
import os

/// Sends the Crashpad minidumps of Chromium processes to Sentry (p09-observability-105), one event per dump,
/// redacted by ``ChromiumMinidump``.
///
/// Crashpad runs with no `ServerURL` (``CEFCrashReporterConfig``), so it writes each report into
/// its local database and never uploads. A finished report is `<uuid>.dmp` in the database's `pending` or
/// `completed` folder (crashpad/client/crash_report_database_mac.mm; `new` holds reports still being written). Each
/// pass of ``SystemCrashForwarder`` (launch and every crash report folder change) runs ``forwardNew(now:)`` first:
/// - consent off (`mayForward` false): every dump is deleted unsent, so turning reports on later never sends a
///   crash from a time they were off;
/// - the app's own process (the browser process when Chromium runs in the app): deleted, Sentry has that crash;
/// - otherwise: uploaded once, then deleted when Sentry stores or refuses it; left for the next launch when the
///   upload fails.
///
/// Crashpad forwards only the browser process's crashes to macOS (BrowserCrashForwardingEnabled), so only a
/// Chromium host also leaves an `.ips`. ``SentPIDs`` lets ``SystemCrashForwarder`` drop that `.ips`: same pid,
/// written within ``SentPIDs/matchWindow`` of the dump.
public final class ChromiumMinidumpForwarder: Sendable {
    /// The labels every minidump event carries, as ``CrashEventLabels`` gives SDK events.
    public struct Labels: Sendable, Equatable {
        public var release: String
        public var dist: String
        public var environment: String
        public var tags: [String: String]

        public init(release: String, dist: String, environment: String, tags: [String: String]) {
            self.release = release
            self.dist = dist
            self.environment = environment
            self.tags = tags
        }

        /// The labels of `policy`'s events.
        public init(policy: CrashReportingPolicy) {
            var tags = ["app": CrashEventLabels.app, "channel": policy.channel?.rawValue ?? "unknown"]
            if let tag = policy.devTag { tags["dev_tag"] = tag }
            self.init(release: policy.release, dist: policy.dist, environment: policy.environment, tags: tags)
        }
    }

    /// The pids whose dump was sent, for dropping the matching `.ips`.
    public struct SentPIDs: Sendable, Equatable {
        /// An `.ips` is the same crash as a dump when written this close to it.
        public static let matchWindow: TimeInterval = 300
        var entries: [Entry]

        struct Entry: Codable, Sendable, Equatable {
            var pid: Int32
            var writtenAt: Double
        }

        /// Whether a crash report of `pid` written at `time` is a sent dump's crash.
        public func covers(pid: Int32, at time: Date) -> Bool {
            entries.contains { $0.pid == pid && abs($0.writtenAt - time.timeIntervalSince1970) <= Self.matchWindow }
        }
    }

    struct State: Codable, Equatable {
        var sent: [SentPIDs.Entry]
    }

    /// The finished-report folders of a Crashpad database.
    static let finishedFolders = ["pending", "completed"]
    /// Dumps larger than this are deleted unread.
    static let maxDumpBytes = 32 << 20
    /// Sent pids are kept this long, at most ``maxSentEntries``.
    static let sentRetention: TimeInterval = 86_400
    static let maxSentEntries = 64

    private let database: @Sendable () -> URL?
    private let stateFile: URL
    private let mainExecutableName: String?
    private let mayForward: @Sendable () -> Bool
    private let labels: Labels
    private let uploader: any MinidumpUploading
    /// Dumps whose upload has not answered yet: a pass during the upload does not send them again.
    private let inFlight = Mutex<Set<String>>([])
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")

    /// - Parameters:
    ///   - database: The Crashpad database, or nil when this build runs no Crashpad; called on the forwarder's
    ///     queue, since finding it reads the bundle.
    ///   - stateFile: Where the sent pids are kept across launches.
    ///   - mainExecutableName: The app executable's file name: its own dumps are never sent.
    ///   - mayForward: Whether dumps may be sent now (Nightly, hang report consent, crash reports on); read each pass.
    ///   - labels: The event labels.
    ///   - uploader: Where dumps go.
    public init(database: @escaping @Sendable () -> URL?, stateFile: URL, mainExecutableName: String?,
                mayForward: @escaping @Sendable () -> Bool, labels: Labels, uploader: any MinidumpUploading) {
        self.database = database
        self.stateFile = stateFile
        self.mainExecutableName = mainExecutableName
        self.mayForward = mayForward
        self.labels = labels
        self.uploader = uploader
    }

    /// Sends or deletes every finished dump (see the type), on the calling thread, which may block on files.
    /// - Returns: The pids of the dumps sent this pass and in the last ``sentRetention``.
    @discardableResult
    public func forwardNew(now: Date) -> SentPIDs {
        guard let database = database() else { return SentPIDs(entries: []) }
        var state = loadState() ?? State(sent: [])
        let before = state
        let allowed = mayForward()
        for url in finishedDumps(in: database) {
            if let entry = forward(url, allowed: allowed) { state.sent.append(entry) }
        }
        state.sent = Array(state.sent.filter { now.timeIntervalSince1970 - $0.writtenAt <= Self.sentRetention }
            .suffix(Self.maxSentEntries))
        if state != before { save(state) }
        return SentPIDs(entries: state.sent)
    }

    /// The finished `.dmp` files of `database`, oldest first.
    private func finishedDumps(in database: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = Self.finishedFolders.flatMap { folder in
            (try? FileManager.checked.contentsOfDirectory(at: database.appending(path: folder, directoryHint: .isDirectory),
                                                          includingPropertiesForKeys: keys)) ?? []
        }
        let dumps = files.filter { $0.pathExtension == "dmp" }
        let modified = { (url: URL) -> Date in
            (try? url.blockingResourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
        }
        return dumps.map { ($0, modified($0)) }.sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    /// Handles one dump; returns its sent pid entry when it is uploaded.
    private func forward(_ url: URL, allowed: Bool) -> SentPIDs.Entry? {
        let name = url.lastPathComponent
        guard !inFlight.withLock({ $0.contains(name) }) else { return nil }
        guard allowed else { return discard(url, reason: "reports off") }
        let size = (try? url.blockingResourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= Self.maxDumpBytes, let data = try? Data(blockingContentsOf: url) else {
            return discard(url, reason: "too large or unreadable")
        }
        let dump: ChromiumMinidump
        do {
            dump = try ChromiumMinidump(data: data)
        } catch {
            return discard(url, reason: "not a readable minidump: \(error)")
        }
        if let main = mainExecutableName, dump.mainModule == main { return discard(url, reason: "the app's own crash") }
        inFlight.withLock { _ = $0.insert(name) }
        uploader.upload(request(for: dump, name: name)) { [self] outcome in finish(url, name: name, outcome: outcome) }
        logger.info("forwarding minidump process=\(dump.processType ?? "browser", privacy: .public)")
        return dump.processID.map { SentPIDs.Entry(pid: $0, writtenAt: dump.writtenAt.timeIntervalSince1970) }
    }

    /// The upload request of `dump`.
    func request(for dump: ChromiumMinidump, name: String) -> MinidumpUploadRequest {
        var tags = labels.tags
        tags["crash_source"] = "crashpad_minidump"
        tags["process_type"] = dump.processType ?? "browser"
        if let module = dump.mainModule { tags["process"] = module }
        if let version = dump.annotations["ver"] { tags["chromium_ver"] = version }
        return MinidumpUploadRequest(fileName: name, minidump: dump.redacted, event: .init(
            release: labels.release, dist: labels.dist, environment: labels.environment, tags: tags,
            fingerprint: [CrashEventLabels.app, "{{ default }}"]))
    }

    private func finish(_ url: URL, name: String, outcome: MinidumpUploadOutcome) {
        switch outcome {
        case .accepted, .refused:
            try? FileManager.checked.removeItem(at: url)
        case .retryLater:
            logger.notice("minidump upload failed; the next launch retries")
        }
        inFlight.withLock { _ = $0.remove(name) }
    }

    private func discard(_ url: URL, reason: String) -> SentPIDs.Entry? {
        try? FileManager.checked.removeItem(at: url)
        logger.info("minidump not sent: \(reason, privacy: .public)")
        return nil
    }

    private func loadState() -> State? {
        guard let data = try? Data(blockingContentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func save(_ state: State) {
        do {
            try FileManager.checked.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).blockingWrite(to: stateFile, options: .atomic)
        } catch {
            logger.error("minidump forwarder state not saved: \(String(describing: error), privacy: .public)")
        }
    }
}
