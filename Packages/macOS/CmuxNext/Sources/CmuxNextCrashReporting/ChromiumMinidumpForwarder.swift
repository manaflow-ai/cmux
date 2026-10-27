public import Foundation
public import Sentry
import CmuxNextCompat
import os

/// Sends the Crashpad minidumps of Chromium processes to Sentry (p09-observability-105), one event per dump.
///
/// Crashpad runs with no `ServerURL` (``CEFCrashReporterConfig``), so it writes each report into
/// its local database and never uploads. A finished report is `<uuid>.dmp` in the database's `pending` or
/// `completed` folder (crashpad/client/crash_report_database_mac.mm; `new` holds reports still being written). Each
/// pass of ``SystemCrashForwarder`` (launch, every crash report folder change, and the hang report decision when a
/// pass waited for it) runs ``forwardNew(now:)`` first. What it does with each dump is the ``Mode`` read at the pass:
/// - ``Mode/discard`` (crash reports off): deleted unsent, so turning reports on later never sends a crash from a
///   time they were off;
/// - ``Mode/summary`` (crash reports on, no hang report consent): one crash event like the one a macOS crash report
///   gives (``ChromiumMinidumpCrashEvent``), since Crashpad takes the crash and macOS writes no report for Chromium's
///   child processes; a dump written without a crash (``ChromiumMinidump/isSimulated``) is deleted;
/// - ``Mode/upload`` (and hang report consent): the dump, redacted by ``ChromiumMinidump``, to Sentry's minidump
///   endpoint; deleted when Sentry stores or refuses it, left for the next launch when the upload fails;
/// - ``Mode/wait`` (the hang report setting not applied yet this launch): left in place for a later pass.
///
/// The app's own process (the browser process when Chromium runs in the app) is always deleted: Sentry has that crash.
///
/// Crashpad forwards only the browser process's crashes to macOS (BrowserCrashForwardingEnabled), so only a
/// Chromium host also leaves an `.ips`. ``SentPIDs`` lets ``SystemCrashForwarder`` drop that `.ips`: same pid,
/// written within ``SentPIDs/matchWindow`` of a crash dump that was sent or still waits.
public final class ChromiumMinidumpForwarder: Sendable {
    /// What a pass does with each dump (see the type).
    public enum Mode: Sendable, Equatable {
        case discard
        case summary
        case upload
        case wait
    }

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

        /// These labels with the release and dist of the build that wrote `dump`, when it names one: a dump is often
        /// sent by the launch after an update.
        public func of(_ dump: ChromiumMinidump) -> Labels {
            var labels = self
            guard let build = dump.crashedBuild else {
                if let ver = dump.annotations["ver"] { labels.tags["chromium_ver"] = ver }
                return labels
            }
            labels.release = CrashReportingPolicy.release(shortVersion: build.version, build: build.build)
            labels.dist = build.build
            if let chromium = build.chromium { labels.tags["chromium_ver"] = chromium }
            return labels
        }
    }

    /// The hang report decision a pass waits for (``Mode/wait``): the hang report controller sets it each time it
    /// applies the setting (on: the setting is on, this Mac's consent is recorded and no managed policy blocks it).
    /// When a pass waited, the first decision runs the action given to ``whenWaitEnds(_:)``.
    public final class Consent: Sendable {
        private struct State {
            var decision: Bool?
            var waited = false
            var waitEnded: (@Sendable () -> Void)?
        }

        private let state = Mutex(State())

        public init() {}

        /// The decision now; nil until the controller applies the setting, which marks that a pass waited.
        public func decisionForPass() -> Bool? {
            state.withLock { state in
                if state.decision == nil { state.waited = true }
                return state.decision
            }
        }

        /// The controller's decision; runs the wait's action once when a pass waited for it.
        public func decide(_ on: Bool) {
            let action = state.withLock { state -> (@Sendable () -> Void)? in
                state.decision = on
                guard state.waited else { return nil }
                state.waited = false
                return state.waitEnded
            }
            action?()
        }

        /// What runs when a pass waited and the decision then comes (another pass).
        public func whenWaitEnds(_ action: @escaping @Sendable () -> Void) {
            state.withLock { $0.waitEnded = action }
        }
    }

    /// The pids of crash dumps sent or waiting, for dropping the matching `.ips`.
    public struct SentPIDs: Sendable, Equatable {
        /// An `.ips` is the same crash as a dump when written this close to it.
        public static let matchWindow: TimeInterval = 300
        var entries: [Entry]

        struct Entry: Codable, Sendable, Equatable {
            var pid: Int32
            var writtenAt: Double
        }

        /// Whether a crash report of `pid` written at `time` is a sent or waiting dump's crash.
        public func covers(pid: Int32, at time: Date) -> Bool {
            entries.contains { $0.pid == pid && abs($0.writtenAt - time.timeIntervalSince1970) <= Self.matchWindow }
        }
    }

    struct State: Codable, Equatable {
        var sent: [SentPIDs.Entry]
    }

    /// What one dump came to.
    private enum Handled {
        /// Deleted, or a report that is not a crash: covers no `.ips`.
        case nothing
        /// Sent or being sent: its pid covers the `.ips` from now on.
        case sent(SentPIDs.Entry)
        /// Left for a later pass: covers the `.ips` this pass.
        case waiting(SentPIDs.Entry)
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
    private let mode: @Sendable () -> Mode
    private let labels: Labels
    private let uploader: any MinidumpUploading
    private let capture: @Sendable (Event) -> Void
    /// Dumps whose upload has not answered yet: a pass during the upload does not send them again.
    private let inFlight = Mutex<Set<String>>([])
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")

    /// - Parameters:
    ///   - database: The Crashpad database, or nil when this build runs no Crashpad; called on the forwarder's
    ///     queue, since finding it reads the bundle.
    ///   - stateFile: Where the sent pids are kept across launches.
    ///   - mainExecutableName: The app executable's file name: its own dumps are never sent.
    ///   - mode: What this pass does with each dump; read once per pass.
    ///   - labels: The event labels of this launch (a dump that names its build gets that build's release).
    ///   - uploader: Where uploaded dumps go.
    ///   - capture: Where crash summaries go.
    public init(database: @escaping @Sendable () -> URL?, stateFile: URL, mainExecutableName: String?,
                mode: @escaping @Sendable () -> Mode, labels: Labels, uploader: any MinidumpUploading,
                // A clean scope: the app's breadcrumbs and contexts do not describe a Chromium process's crash.
                capture: @escaping @Sendable (Event) -> Void = { SentrySDK.capture(event: $0, scope: Scope()) }) {
        self.database = database
        self.stateFile = stateFile
        self.mainExecutableName = mainExecutableName
        self.mode = mode
        self.labels = labels
        self.uploader = uploader
        self.capture = capture
    }

    /// Handles every finished dump (see the type), on the calling thread, which may block on files.
    /// - Returns: The pids of the crash dumps sent this pass and in the last ``sentRetention``, and of those that wait.
    @discardableResult
    public func forwardNew(now: Date) -> SentPIDs {
        guard let database = database() else { return SentPIDs(entries: []) }
        var state = loadState() ?? State(sent: [])
        let before = state
        let mode = mode()
        var waiting: [SentPIDs.Entry] = []
        for url in finishedDumps(in: database) {
            switch forward(url, mode: mode) {
            case .nothing: break
            case .sent(let entry): state.sent.append(entry)
            case .waiting(let entry): waiting.append(entry)
            }
        }
        state.sent = Array(state.sent.filter { now.timeIntervalSince1970 - $0.writtenAt <= Self.sentRetention }
            .suffix(Self.maxSentEntries))
        if state != before { save(state) }
        return SentPIDs(entries: state.sent + waiting)
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

    /// Handles one dump.
    private func forward(_ url: URL, mode: Mode) -> Handled {
        let name = url.lastPathComponent
        guard !inFlight.withLock({ $0.contains(name) }) else { return .nothing }
        guard mode != .discard else { return discard(url, reason: "reports off") }
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
        // A dump written without a crash: its process may still run, so its pid covers no later crash report.
        let entry = dump.isSimulated ? nil : dump.processID.map { SentPIDs.Entry(pid: $0, writtenAt: dump.writtenAt.timeIntervalSince1970) }
        let process = dump.processType ?? "browser"
        switch mode {
        case .discard:
            return .nothing
        case .wait:
            return entry.map(Handled.waiting) ?? .nothing
        case .summary:
            guard !dump.isSimulated else { return discard(url, reason: "a dump without a crash, no consent to upload") }
            capture(ChromiumMinidumpCrashEvent(dump: dump, labels: labels.of(dump)).event())
            try? FileManager.checked.removeItem(at: url)
            logger.info("forwarded minidump crash summary process=\(process, privacy: .public)")
        case .upload:
            inFlight.withLock { _ = $0.insert(name) }
            uploader.upload(request(for: dump, name: name)) { [self] outcome in finish(url, name: name, outcome: outcome) }
            logger.info("forwarding minidump process=\(process, privacy: .public) simulated=\(dump.isSimulated, privacy: .public)")
        }
        return entry.map(Handled.sent) ?? .nothing
    }

    /// The upload request of `dump`: a crash is fatal; a dump written without one is a warning tagged
    /// `dump_kind: simulated`, so it never counts as a crash.
    func request(for dump: ChromiumMinidump, name: String) -> MinidumpUploadRequest {
        let labels = labels.of(dump)
        var tags = labels.tags
        tags["crash_source"] = "crashpad_minidump"
        tags["process_type"] = dump.processType ?? "browser"
        tags["dump_kind"] = dump.isSimulated ? "simulated" : "crash"
        if let module = dump.mainModule { tags["process"] = module }
        return MinidumpUploadRequest(fileName: name, minidump: dump.redacted, event: .init(
            release: labels.release, dist: labels.dist, environment: labels.environment,
            level: dump.isSimulated ? "warning" : "fatal", tags: tags,
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

    private func discard(_ url: URL, reason: String) -> Handled {
        try? FileManager.checked.removeItem(at: url)
        logger.info("minidump not sent: \(reason, privacy: .public)")
        return .nothing
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
