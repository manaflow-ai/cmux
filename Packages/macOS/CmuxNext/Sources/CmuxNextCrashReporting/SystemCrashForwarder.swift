public import Foundation
public import Sentry
import CmuxNextCompat
import os

/// Sends the crash reports macOS writes for this app's helper processes
/// (cmux-tui daemon and hosts, acpmux, Chromium helpers) to Sentry.
///
/// Decision (cx-urd.58): the Rust daemons carry no Sentry SDK. They run
/// headless and outlive the app, so they have no consent state of their
/// own, and the SDK would bring an HTTP and TLS stack into the daemon. A
/// native crash in any process already produces a macOS crash report; the
/// app, which owns consent, forwards the reports of binaries inside its own
/// bundle once each, with frames Sentry symbolicates from the nightly's
/// debug files. Reports written before the first forwarder run are never
/// sent. The app's own crashes are Sentry's (in-process), so its executable
/// is skipped.
public final class SystemCrashForwarder: Sendable {
    /// Where macOS writes the current user's crash reports.
    public static let standardDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    /// Reports larger than this are not read.
    static let maxReportBytes = 8 << 20
    /// A report that does not parse yet and is younger than this may still
    /// be in the writing: it stays pending (the watermark stops before it).
    static let writeGrace: TimeInterval = 60

    struct State: Codable, Equatable {
        /// Reports modified at or before this time are done.
        var watermark: Double
        /// Reports at exactly the watermark that were already sent.
        var sentAtWatermark: [String]
    }

    private let directory: URL
    private let stateFile: URL
    private let bundlePath: String
    private let mainExecutable: String?
    /// False when crash reports are off this launch: reports are marked done
    /// without being sent, so turning reports on later never sends crashes
    /// from a time they were off.
    private let sends: Bool
    private let capture: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.crash-forwarder", qos: .utility)
    private let watcher = Mutex<(any DispatchSourceFileSystemObject)?>(nil)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")

    public init(directory: URL = SystemCrashForwarder.standardDirectory, stateFile: URL, bundlePath: String,
                mainExecutable: String?, sends: Bool = true,
                // A clean scope: the app's breadcrumbs and contexts do not describe a helper's crash.
                capture: @escaping @Sendable (Event) -> Void = { SentrySDK.capture(event: $0, scope: Scope()) }) {
        self.directory = directory
        self.stateFile = stateFile
        self.bundlePath = bundlePath
        self.mainExecutable = mainExecutable
        self.sends = sends
        self.capture = capture
    }

    /// Sends every helper report written since the last run, now and each
    /// time macOS writes into the report folder, off the main thread (with
    /// `sends` false: marks them done).
    public func start() {
        queue.async { [self] in
            forwardNew(now: Date())
            watch()
        }
    }

    /// Sends the reports newer than the saved watermark and moves it.
    /// The first run only sets the watermark. Returns the files sent.
    @discardableResult
    public func forwardNew(now: Date) -> [URL] {
        guard var state = loadState() else {
            save(State(watermark: now.timeIntervalSince1970, sentAtWatermark: []))
            return []
        }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        var candidates: [(url: URL, time: Double)] = []
        for url in files where url.pathExtension == "ips" {
            guard let values = try? url.resourceValues(forKeys: keys), let modified = values.contentModificationDate,
                  (values.fileSize ?? 0) <= Self.maxReportBytes else { continue }
            let time = modified.timeIntervalSince1970
            if time > state.watermark || (time == state.watermark && !state.sentAtWatermark.contains(url.lastPathComponent)) {
                candidates.append((url, time))
            }
        }
        var sent: [URL] = []
        var changed = false
        for candidate in candidates.sorted(by: { $0.time < $1.time }) {
            // Reports are off: never read, only marked done.
            let contents: SystemCrashReport.Contents = !sends ? .other
                : (try? Data(contentsOf: candidate.url)).map(SystemCrashReport.contents(of:)) ?? .incomplete
            switch contents {
            case .incomplete where now.timeIntervalSince1970 - candidate.time < Self.writeGrace:
                // Still being written: retried at the next folder event or launch.
                if changed { save(state) }
                return sent
            case .crash(let report) where report.isHelper(ofBundle: bundlePath, mainExecutable: mainExecutable):
                capture(SystemCrashEvent(report: report).event())
                sent.append(candidate.url)
                logger.info("forwarded crash report process=\(report.processName, privacy: .public)")
            default:
                break
            }
            changed = true
            if candidate.time > state.watermark {
                state = State(watermark: candidate.time, sentAtWatermark: [])
            }
            state.sentAtWatermark.append(candidate.url.lastPathComponent)
        }
        if changed { save(state) }
        return sent
    }

    private func watch() {
        // macOS creates the folder at the first crash report; watch it from now on.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename],
                                                               queue: queue)
        source.setEventHandler { [weak self] in self?.forwardNew(now: Date()) }
        source.setCancelHandler { close(descriptor) }
        watcher.withLock { $0 = source }
        source.resume()
    }

    private func loadState() -> State? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func save(_ state: State) {
        do {
            try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
        } catch {
            logger.error("crash forwarder state not saved: \(String(describing: error), privacy: .public)")
        }
    }
}
