public import Foundation
public import Sentry
import CmuxNextCompat
import CmuxNextWakeups
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
/// Every cmux app on the Mac shares that root, so a copy's crash is forwarded only
/// when its image (``MachOImageUUIDs``) is one this app ran: each launch adds its
/// Rust binaries' UUIDs and its release to the forwarder state. An earlier build's
/// copy that a holder or host kept running across an update (pty-holder.md) is
/// still this app's, and its event gets that build's release. Another app's copy
/// is left to that app and its consent. A Rust process's report carries its crash keys and black
/// box (``RustCrashArtifacts``). Reports written before the first forwarder run
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

    /// The most Rust images ``State/ownImages`` keeps: the oldest go first.
    static let maxOwnImages = 64

    struct State: Codable, Equatable {
        /// Reports modified at or before this time are done.
        var watermark: Double
        /// Reports at exactly the watermark that were already sent.
        var sentAtWatermark: [String]
        /// This app's Rust images, newest last: the binaries each launch ran, with that launch's release. Nil in
        /// a state written before the list.
        var ownImages: [OwnImage]?

        /// One of this app's Rust images: its `LC_UUID` as 32 lowercase hex digits, and the release that ran it.
        struct OwnImage: Codable, Equatable {
            var uuid: String
            var release: String?
        }

        /// Puts `images` last with `release`; the oldest beyond ``SystemCrashForwarder/maxOwnImages`` go. Returns
        /// whether the list changed.
        mutating func remember(_ images: MachOImageUUIDs, release: String?) -> Bool {
            let running = images.uuids.map(SystemCrashForwarder.hex).sorted()
            let before = ownImages ?? []
            let after = Array((before.filter { !running.contains($0.uuid) }
                + running.map { OwnImage(uuid: $0, release: release) }).suffix(SystemCrashForwarder.maxOwnImages))
            ownImages = after
            return after != before
        }

        /// The image `uuid` (a report's `8-4-4-4-12` text) when this app ran it, else nil.
        func ownImage(_ uuid: String?) -> OwnImage? {
            guard let hex = uuid.flatMap(RustCrashArtifacts.uuidBytes).map(SystemCrashForwarder.hex) else { return nil }
            return ownImages?.last(where: { $0.uuid == hex })
        }
    }

    private let directory: URL
    private let stateFile: URL
    private let roots: SystemCrashReport.HelperRoots
    /// This app's Rust binaries a host-exe copy is made from: read once per launch into ``State/ownImages``, and in
    /// each pass that meets a host-exe crash (the `process_build` tag).
    private let ownRustBinaries: [URL]
    /// This app's Sentry release, recorded with its binaries' images.
    private let release: String?
    /// Whether this launch's binaries are in the state already.
    private let rememberedOwnImages = Atomic<Bool>(false)
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
    /// The folder watch's record in the launch's arm census (Debug and bench builds, p08-startup-085).
    private let census: ArmCensusWatch

    /// - Parameters:
    ///   - hostExeRoot: The root of the daemon's host and holder copies
    ///     (``SystemCrashReport/HelperRoots/standardHostExeRoot(environment:home:)`` of the daemon's environment,
    ///     not the app's, whose launch strips `CMUX_TUI_HOST_EXE_DIR`); nil forwards bundle binaries only.
    ///   - ownRustBinaries: This app's binaries the daemon copies under the host-exe root (the daemon and the
    ///     `cmux-tui-host` and `cmux-holder` beside it). A copy's crash is forwarded only when its image is one of
    ///     theirs or of an earlier launch's, tagged `process_build` `this` or `other`.
    ///   - release: This app's Sentry release (`CrashReportingPolicy.release`), recorded with this launch's images: a
    ///     host-exe crash gets the release of the newest launch that ran its image; nil leaves the SDK's.
    ///   - artifacts: Where the Rust processes' black boxes and crash-key pages are, with the hang-reports
    ///     opt-in that lets a black box leave; nil attaches none.
    ///   - capture: Sends an event with its attachments.
    ///   - file: With `line`, names the line that made it in the arm census (leave the defaults).
    public init(directory: URL = SystemCrashForwarder.standardDirectory, stateFile: URL, bundlePath: String,
                mainExecutable: String?,
                hostExeRoot: String?,
                ownRustBinaries: [URL],
                release: String? = nil,
                artifacts: RustCrashArtifacts?,
                sends: Bool = true, file: StaticString = #fileID, line: UInt = #line,
                capture: @escaping @Sendable (Event, [Attachment]) -> Void = { SystemCrashForwarder.sendToSentry($0, attachments: $1) }) {
        self.directory = directory
        self.stateFile = stateFile
        roots = SystemCrashReport.HelperRoots(bundlePath: bundlePath, mainExecutable: mainExecutable, hostExeRoot: hostExeRoot)
        self.ownRustBinaries = ownRustBinaries
        self.release = release
        self.artifacts = artifacts
        self.sends = sends
        self.capture = capture
        census = ArmCensusWatch(.watcher, owner: "SystemCrashForwarder", file: file, line: line)
    }

    /// The binaries in `directories` the daemon copies under the host-exe root
    /// (``SystemCrashReport/HelperRoots/hostExeNames``).
    public static func rustBinaries(in directories: [URL]) -> [URL] {
        directories.flatMap { directory in
            SystemCrashReport.HelperRoots.hostExeNames.sorted().map { directory.appending(path: $0) }
        }
    }

    /// The Rust binaries an app's daemon copies under the host-exe root: the daemon a dev build runs instead of
    /// the bundled one (`daemonOverride`, `CMUX_NEXT_TUI_BIN`, CmuxNextDaemon `DaemonLauncher.resolveBinary`) and
    /// the host and holder beside it (cmux-tui-platform `host_exe`), then those in the bundle's `bundledBin`.
    /// No file is read here.
    public static func ownRustBinaries(bundledBin: URL?, daemonOverride: String?) -> [URL] {
        var binaries: [URL] = []
        var directories: [URL] = []
        if let daemonOverride, !daemonOverride.isEmpty {
            let daemon = URL(fileURLWithPath: daemonOverride)
            binaries.append(daemon)
            directories.append(daemon.deletingLastPathComponent())
        }
        if let bundledBin { directories.append(bundledBin) }
        return binaries + rustBinaries(in: directories)
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
        queue.async { [self] in forwardAndWatch() }
    }

    /// ``start()``'s work on the calling thread, which may block on files (a launch lane post,
    /// ``CrashForwarders/run()``): sends the reports written since the last run, then watches the
    /// folder on the forwarder's queue. Call it, or ``start()``, once.
    public func forwardAndWatch() {
        forwardNew(now: Date())
        watch()
    }

    /// Sends the reports newer than the saved watermark and moves it.
    /// The first run only sets the watermark. Returns the files sent.
    @discardableResult
    public func forwardNew(now: Date) -> [URL] {
        let loaded = loadState()
        var state = loaded ?? State(watermark: now.timeIntervalSince1970, sentAtWatermark: [])
        var changed = loaded == nil
        // Once per launch, with reports on or off, so a later launch knows this one's copies.
        var running: MachOImageUUIDs?
        if !rememberedOwnImages.exchange(true, ordering: .relaxed) {
            let images = MachOImageUUIDs(files: ownRustBinaries)
            running = images
            if state.remember(images, release: release) { changed = true }
        }
        guard loaded != nil else {
            save(state)
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
        let roots = sends && !candidates.isEmpty ? self.roots.resolvingHostExeRoot() : self.roots
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
                var own: State.OwnImage?
                if origin == .hostExe {
                    // Another app's copy: left to that app, its consent and its release.
                    guard let image = state.ownImage(report.mainImageUUID) else { break }
                    own = image
                }
                var extras = artifacts?.extras(for: report) ?? SystemCrashEvent.Extras()
                extras.origin = origin
                if let own {
                    let images = running ?? MachOImageUUIDs(files: ownRustBinaries)
                    running = images
                    extras.fromThisBuild = images.contains(report.mainImageUUID)
                    extras.release = own.release
                }
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
                state.watermark = candidate.time
                state.sentAtWatermark = []
            }
            state.sentAtWatermark.append(candidate.url.lastPathComponent)
        }
        if changed { save(state) }
        return sent
    }

    /// `bytes` as lowercase hex digits.
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { ($0 < 0x10 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    private func watch() {
        // macOS creates the folder at the first crash report; watch it from now on.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let descriptor = unsafe blockingOpen(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename],
                                                               queue: queue)
        source.setEventHandler { [weak self] in
            self?.census.fired()
            self?.forwardNew(now: Date())
        }
        source.setCancelHandler { close(descriptor) }
        watcher.withLock { $0 = source }
        source.resume()
        census.armed()
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
