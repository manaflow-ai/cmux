public import Foundation

/// The consolidated on-disk application log: one rotating file for app-wide
/// events and one for network diagnostics.
///
/// ``AppLog`` is the durable half of the diagnostics stack. The in-memory
/// ``DiagnosticLog`` ring stays the single structured spine every subsystem
/// records into; the composition root taps that ring into an ``AppLog``, which
/// renders each event through ``DiagnosticEventPresentation`` and appends it to
/// one of two files:
///
/// - the **app log** (``appLogFileName``): every event that is not
///   network-plane — simulator streaming/control, browser streaming, composer,
///   render — plus mirrored string debug-log lines, so one file tells the whole
///   in-app story in wall-clock order;
/// - the **network log** (``networkLogFileName``): transport dials, discovery,
///   relay policy, path changes, session lifecycle and close attribution.
///
/// Cross-cutting context (app lifecycle, reachability) is written to both so
/// each file is self-sufficient. Diagnostic events are integer-encoded and
/// privacy-safe by construction, so persistence is always on, including
/// Release; the free-text mirror keeps the string log's own gating (DEBUG
/// always, Release behind the verbose opt-in) because those lines are not
/// structurally scrubbed.
///
/// Ordering: both entry points are non-blocking and feed one buffered stream
/// drained by a single internal task, so lines land on disk in admission
/// order. Consecutive frame-pipeline events for the same panel and stage are
/// coalesced into a `repeated ×N` summary when the run breaks, so a healthy
/// 20 fps stream costs one line plus one summary instead of megabytes.
///
/// Inject one instance from the app composition root; do not add a `.shared`
/// singleton.
public actor AppLog {
    /// Which on-disk file an event belongs to.
    public enum Domain: Sendable, Equatable {
        case app
        case network
        case both
    }

    public static let appLogFileName = "cmux-app.log"
    public static let networkLogFileName = "cmux-network.log"

    /// Default location of the app-wide log inside Application Support, or
    /// `nil` when the directory cannot be resolved. Exists so settings UI can
    /// offer the file for sharing without holding the ``AppLog`` instance.
    public static var defaultAppLogFileURL: URL? {
        defaultFileURL(named: appLogFileName)
    }

    /// Default location of the network diagnostics log. See
    /// ``defaultAppLogFileURL``.
    public static var defaultNetworkLogFileURL: URL? {
        defaultFileURL(named: networkLogFileName)
    }

    private static func defaultFileURL(named name: String) -> URL? {
        let fileManager = FileManager.default
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        do {
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return base.appendingPathComponent(name)
    }

    private enum Entry: Sendable {
        case event(DiagnosticEvent, wall: Date)
        case appLine(String, wall: Date)
    }

    private struct LogFile {
        let url: URL
        let maxBytes: Int
        let header: String
        var handle: FileHandle?
        var bytesWritten = 0
        /// Byte level at which the next rotation is attempted. Normally
        /// `maxBytes`; raised after a failed rotate so a sustained failure
        /// (busy file, read-only directory) retries once per additional
        /// budget of growth instead of once per appended line.
        var rotationThreshold: Int

        init(url: URL, maxBytes: Int, header: String) {
            self.url = url
            self.maxBytes = maxBytes
            self.header = header
            self.rotationThreshold = maxBytes
            openFreshGeneration(rotatingExisting: true)
        }

        /// Rotates `<name>` to `<name>.1` (replacing any previous `.1`) and
        /// opens a fresh file with the header line. A failed rotate falls back
        /// to appending to the existing generation: truncating in place would
        /// erase the very diagnostics a user may be about to share. Only a
        /// failed open disables writing, and for this file only.
        private mutating func openFreshGeneration(rotatingExisting: Bool) {
            let fileManager = FileManager.default
            if rotatingExisting, fileManager.fileExists(atPath: url.path) {
                let rotated = url.appendingPathExtension("1")
                try? fileManager.removeItem(at: rotated)
                do {
                    try fileManager.moveItem(at: url, to: rotated)
                } catch {
                    openExistingForAppending()
                    return
                }
            }
            fileManager.createFile(atPath: url.path, contents: nil)
            guard let opened = try? FileHandle(forWritingTo: url) else {
                handle = nil
                return
            }
            handle = opened
            bytesWritten = 0
            rotationThreshold = maxBytes
            write(header)
        }

        /// Keeps writing to the current generation after a failed rotate,
        /// with no extra header (the file already carries its generation
        /// header, and a sustained failure must not add one per retry). The
        /// raised threshold makes the next retry wait for another full byte
        /// budget, so the fallback is bounded churn, not per-line reopens.
        private mutating func openExistingForAppending() {
            guard let opened = try? FileHandle(forWritingTo: url),
                  let size = try? opened.seekToEnd() else {
                // A generation that cannot be opened or positioned at its end
                // is not safely appendable: writing from offset 0 would
                // overwrite the content this fallback exists to preserve.
                handle = nil
                return
            }
            handle = opened
            bytesWritten = Int(clamping: size)
            rotationThreshold = bytesWritten + maxBytes
        }

        mutating func append(_ line: String) {
            guard handle != nil else { return }
            let data = Data((line + "\n").utf8)
            if bytesWritten + data.count > rotationThreshold {
                try? handle?.close()
                handle = nil
                openFreshGeneration(rotatingExisting: true)
                guard handle != nil else { return }
            }
            write(line)
        }

        private mutating func write(_ line: String) {
            guard let handle else { return }
            let data = Data((line + "\n").utf8)
            do {
                try handle.write(contentsOf: data)
                bytesWritten += data.count
            } catch {
                try? handle.close()
                self.handle = nil
            }
        }

        mutating func close() {
            try? handle?.close()
            handle = nil
        }
    }

    /// One in-progress run of coalescible frame events.
    private struct FrameRun {
        let key: FrameRunKey
        var lastEvent: DiagnosticEvent
        var count: Int
    }

    private struct FrameRunKey: Equatable {
        let code: DiagnosticEventCode
        let surface: UInt32?
        let stage: Int?
    }

    private var appFile: LogFile?
    private var networkFile: LogFile?
    private var pendingFrameRun: FrameRun?
    private var processed = 0
    private let presentation = DiagnosticEventPresentation()
    private let timestampFormatter: ISO8601DateFormatter
    private let ingress: AsyncStream<Entry>.Continuation

    /// Create a log writing to the given locations. Passing `nil` for a URL
    /// disables that file (used by tests exercising one file at a time).
    public init(
        appFileURL: URL?,
        networkFileURL: URL?,
        maxFileBytes: Int = 5_000_000,
        buildStamp: String = ""
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        timestampFormatter = formatter
        let started = formatter.string(from: Date())
        if let appFileURL {
            appFile = LogFile(
                url: appFileURL,
                maxBytes: maxFileBytes,
                header: "cmux app log · \(buildStamp) · started \(started)"
            )
        }
        if let networkFileURL {
            networkFile = LogFile(
                url: networkFileURL,
                maxBytes: maxFileBytes,
                header: "cmux network diagnostics log · \(buildStamp) · started \(started)"
            )
        }
        let (stream, continuation) = AsyncStream<Entry>.makeStream(
            bufferingPolicy: .bufferingNewest(2048)
        )
        ingress = continuation
        // The drain holds self only across one write; when the log deallocs,
        // `deinit` finishes the stream and the loop ends on its own.
        Task { [weak self] in
            for await entry in stream {
                guard let self else { return }
                await self.write(entry)
            }
        }
    }

    deinit {
        ingress.finish()
    }

    /// Record one structured diagnostic event. Non-blocking and safe to call
    /// from the ``DiagnosticLog`` event tap (which runs on the ring's drain
    /// task and must not block).
    public nonisolated func ingest(_ event: DiagnosticEvent) {
        ingress.yield(.event(event, wall: Date()))
    }

    /// Mirror one free-text debug-log line into the app file. The caller owns
    /// the privacy gating (the string debug log only produces lines in DEBUG
    /// or behind the user's verbose opt-in).
    public nonisolated func mirrorAppLine(_ line: String) {
        ingress.yield(.appLine(line, wall: Date()))
    }

    /// The total number of entries the drain task has written. Never
    /// decreases, so after admitting `n` entries a test can poll this to `n`
    /// to know everything reached the files, without sleeping.
    public func processedCount() -> Int {
        processed
    }

    /// Flushes a pending coalesced frame run to disk. Test-only
    /// synchronization; in production runs flush when they break.
    public func flushForTesting() {
        flushPendingFrameRun()
    }

    private func write(_ entry: Entry) {
        processed += 1
        switch entry {
        case .event(let event, let wall):
            writeEvent(event, wall: wall)
        case .appLine(let line, let wall):
            flushPendingFrameRun()
            appFile?.append("\(timestampFormatter.string(from: wall)) \(line)")
        }
    }

    private func writeEvent(_ event: DiagnosticEvent, wall: Date) {
        if let key = Self.frameRunKey(for: event) {
            if var run = pendingFrameRun, run.key == key {
                run.lastEvent = event
                run.count += 1
                pendingFrameRun = run
                return
            }
            flushPendingFrameRun()
            appendRendered(event, wall: wall)
            pendingFrameRun = FrameRun(key: key, lastEvent: event, count: 1)
            return
        }
        flushPendingFrameRun()
        appendRendered(event, wall: wall)
    }

    /// Frame-pipeline events repeat at frame cadence with only the sequence
    /// and byte count varying; they coalesce per (code, panel, stage).
    private static func frameRunKey(for event: DiagnosticEvent) -> FrameRunKey? {
        guard event.code == .simulatorFrameLifecycle else { return nil }
        return FrameRunKey(code: event.code, surface: event.surface, stage: event.a)
    }

    private func flushPendingFrameRun() {
        guard let run = pendingFrameRun else { return }
        pendingFrameRun = nil
        guard run.count > 1 else { return }
        let summary = presentation.summary(run.lastEvent)
        append(
            line: "\(timestampFormatter.string(from: Date())) \(summary) (repeated ×\(run.count))",
            domain: run.key.code.appLogDomain
        )
    }

    private func appendRendered(_ event: DiagnosticEvent, wall: Date) {
        append(
            line: "\(timestampFormatter.string(from: wall)) \(presentation.summary(event))",
            domain: event.code.appLogDomain
        )
    }

    private func append(line: String, domain: Domain) {
        switch domain {
        case .app:
            appFile?.append(line)
        case .network:
            networkFile?.append(line)
        case .both:
            appFile?.append(line)
            networkFile?.append(line)
        }
    }
}

public extension DiagnosticEventCode {
    /// Which on-disk log this event belongs to: the app-wide log, the network
    /// diagnostics log, or both (cross-cutting context that keeps each file
    /// self-sufficient). New codes default to the app log.
    var appLogDomain: AppLog.Domain {
        switch self {
        case .connect, .pairOk, .pairFail, .pairUnreachable,
             .livenessResubscribe, .streamEnded, .inputSeqBehind, .byteGap,
             .transportDialStarted, .transportDialConnected, .transportDialFailed,
             .hostAuthenticated, .hostAuthenticationFailed,
             .rpcReady, .rpcFailed,
             .recoveryStarted, .recoverySucceeded, .recoveryFailed,
             .endpointStarting, .endpointActive, .endpointStopped, .endpointFailed,
             .relayPolicyRefreshStarted, .relayPolicyRefreshSucceeded,
             .relayPolicyRefreshFailed,
             .selectedPathChanged, .sessionClosed, .routeUnavailable,
             .retryScheduled,
             .discoveryStarted, .discoverySucceeded, .discoveryFailed,
             .admissionSucceeded, .admissionFailed,
             .transportSessionLifecycle,
             .transportCloseAttribution, .transportPathEvent:
            return .network
        case .appLifecycleChanged, .reachabilityChanged:
            return .both
        default:
            return .app
        }
    }
}
