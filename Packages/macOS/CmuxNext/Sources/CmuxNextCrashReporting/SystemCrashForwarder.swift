public import Foundation
public import Sentry
import CmuxNextCompat
import os

/// Sends the crash reports macOS writes for this app's helper processes
/// (cmux-tui daemon and hosts, the holder, acpmux, Chromium helpers) to Sentry.
///
/// Decision (cx-urd.58): the Rust daemons carry no Sentry SDK. They run
/// headless and outlive the app, so they have no consent state of their
/// own, and the SDK would bring an HTTP and TLS stack into the daemon. A
/// native crash in any process already produces a macOS crash report; the
/// app, which owns consent, forwards the reports of its helpers once each,
/// with frames Sentry symbolicates from the nightly's debug files: the
/// binaries inside its own bundle, and the terminal host and holder copies
/// the daemon runs from the host-exe root (``SystemCrashReport/helperOrigin(in:)``).
/// That root is shared by every cmux build on the Mac, so a copy's crash is
/// forwarded only by the app whose own Rust binaries have the crashed image's
/// `LC_UUID` (``MachOImageUUIDs``): the build that made the copy, with its
/// release, its consent and its trace folder. A Rust process's report
/// carries its crash keys and black box (``RustCrashArtifacts``). Reports written before the first forwarder run
/// are never sent. The app's own crashes are Sentry's (in-process), so its
/// executable is skipped.
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
    private let roots: SystemCrashReport.HelperRoots
    /// This app's Rust binaries a host-exe copy is made from; read in each pass that meets a host-exe crash.
    private let ownRustBinaries: [URL]
    /// Where the Rust processes' black boxes and crash-key pages are; nil: no extras.
    private let artifacts: RustCrashArtifacts?
    /// False when crash reports are off this launch: reports are marked done
    /// without being sent, so turning reports on later never sends crashes
    /// from a time they were off.
    private let sends: Bool
    private let capture: @Sendable (Event, [Attachment]) -> Void
    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.crash-forwarder", qos: .utility)
    private let watcher = Mutex<(any DispatchSourceFileSystemObject)?>(nil)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")

    /// - Parameters:
    ///   - hostExeRoot: The root of the daemon's host and holder copies
    ///     (``SystemCrashReport/HelperRoots/standardHostExeRoot(environment:home:)``); nil forwards bundle binaries only.
    ///   - ownRustBinaries: This app's binaries the daemon copies under the host-exe root (the daemon and the
    ///     `cmux-tui-host` and `cmux-holder` beside it): a copy's crash is forwarded only when its image is one of
    ///     theirs. Empty forwards no host-exe crash.
    ///   - artifacts: Where the Rust processes' black boxes and crash-key pages are, with the hang-reports
    ///     opt-in that lets a black box leave; nil attaches none.
    ///   - capture: Sends an event with its attachments.
    public init(directory: URL = SystemCrashForwarder.standardDirectory, stateFile: URL, bundlePath: String,
                mainExecutable: String?,
                hostExeRoot: String? = SystemCrashReport.HelperRoots.standardHostExeRoot(),
                ownRustBinaries: [URL],
                artifacts: RustCrashArtifacts?,
                sends: Bool = true,
                capture: @escaping @Sendable (Event, [Attachment]) -> Void = { SystemCrashForwarder.sendToSentry($0, attachments: $1) }) {
        self.directory = directory
        self.stateFile = stateFile
        roots = SystemCrashReport.HelperRoots(bundlePath: bundlePath, mainExecutable: mainExecutable, hostExeRoot: hostExeRoot)
        self.ownRustBinaries = ownRustBinaries
        self.artifacts = artifacts
        self.sends = sends
        self.capture = capture
    }

    /// The binaries in `directories` the daemon copies under the host-exe root
    /// (``SystemCrashReport/HelperRoots/hostExeNames``), for the bundle's `bin` folder and a dev build's daemon
    /// folder.
    public static func rustBinaries(in directories: [URL]) -> [URL] {
        directories.flatMap { directory in
            SystemCrashReport.HelperRoots.hostExeNames.sorted().map { directory.appending(path: $0) }
        }
    }

    /// Sends `event` with `attachments` in a clean scope: the app's breadcrumbs and contexts do not describe a
    /// helper's crash.
    public static func sendToSentry(_ event: Event, attachments: [Attachment]) {
        let scope = Scope()
        for attachment in attachments { scope.addAttachment(attachment) }
        SentrySDK.capture(event: event, scope: scope)
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
        let roots = sends && !candidates.isEmpty ? self.roots.resolvingHostExeRoot() : self.roots
        var ownImages: MachOImageUUIDs?
        for candidate in candidates.sorted(by: { $0.time < $1.time }) {
            // Reports are off: never read, only marked done.
            let contents: SystemCrashReport.Contents = !sends ? .other
                : (try? Data(contentsOf: candidate.url)).map(SystemCrashReport.contents(of:)) ?? .incomplete
            switch contents {
            case .incomplete where now.timeIntervalSince1970 - candidate.time < Self.writeGrace:
                // Still being written: retried at the next folder event or launch.
                if changed { save(state) }
                return sent
            case .crash(let report):
                guard let origin = report.helperOrigin(in: roots) else { break }
                if origin == .hostExe {
                    let images = ownImages ?? MachOImageUUIDs(files: ownRustBinaries)
                    ownImages = images
                    // Another cmux build's copy: that build forwards it.
                    guard images.contains(report.mainImageUUID) else { break }
                }
                var extras = artifacts?.extras(for: report) ?? SystemCrashEvent.Extras()
                extras.origin = origin
                let crash = SystemCrashEvent(report: report, extras: extras)
                capture(crash.event(), crash.attachments())
                sent.append(candidate.url)
                logger.info("""
                    forwarded crash report process=\(report.processName, privacy: .public) \
                    origin=\(origin.rawValue, privacy: .public)
                    """)
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
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let descriptor = unsafe open(directory.path, O_EVTONLY | O_CLOEXEC)
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
