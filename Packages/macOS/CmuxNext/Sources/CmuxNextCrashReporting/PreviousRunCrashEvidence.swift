public import CmuxNextTrace
public import CmuxSentryScrubbing
public import Foundation
public import Sentry
import CmuxNextCompat

/// The previous run's crash keys and black box on that run's crash event, which SentryCrash sends at this launch
/// (plans/cmux-next/chrome-parity/p09-observability.md, task 079):
///
/// - Tags: the run's crash-key page (`<role>-<pid>.crashkeys`, ``CrashKeyPage``) and its crash path's
///   `run.crashkeys` line (``CrashKeys``), each `crash_key.<name>`, where the event has no such tag.
/// - `blackbox.txt`, only with the hang-reports opt-in: the newest 512 events of the run's black box
///   (`<role>-<pid>.blackbox.cmxtrace`), catalog names and numbers through the upload decoder, never a key record
///   (``TraceBlackBoxUpload``), then the scrubber (``CrashReporter/blackboxAttachment(_:hangReportsOptIn:scrubber:)``).
///
/// Only the run's own crash gets them, and once: the first fatal event whose time is not before the run's process
/// start. A crash report an older run left unsent has an earlier time. The files are read when that event is
/// decorated, on the queue Sentry calls `beforeSend` on, so a launch after a clean exit reads nothing, and the ring
/// only with the opt-in. A file whose header names another process (a reused pid) is skipped.
///
/// Chrome sends a crashed session's own data with that session's report the same way: the metrics file the dead
/// browser wrote is read at the next launch and attached to the previous run's stability log
/// (components/metrics/file_metrics_provider.cc, `ASSOCIATE_PREVIOUS_RUN`), and Crashpad uploads the crash keys
/// the process stored before it died (components/crash/core/common/crash_key.h).
///
/// ```swift
/// let evidence = PreviousRunCrashEvidence(run: .init(pid: 4242, processStartUnixMicros: start, traceDirectory: dir),
///                                         hangReportsOptIn: { consented })
/// options.beforeSendWithHint = { event, hint in evidence.decorate(event, hint: hint); return event }
/// ```
public final class PreviousRunCrashEvidence: Sendable {
    /// Where a run left its files and who it was.
    public struct Run: Sendable, Equatable {
        /// The run's pid (its files' names).
        public var pid: UInt32
        /// The run's kernel process start, Unix microseconds; nil when its run marker predates the field.
        public var processStartUnixMicros: UInt64?
        /// The folder of its black box and crash-key page.
        public var traceDirectory: String
        /// Its crash path's `run.crashkeys` line (moved aside at this launch); nil when there is none.
        public var crashPathKeysFile: String?
        /// The process kind in the files' names.
        public var role: TraceRing.Role

        public init(pid: UInt32, processStartUnixMicros: UInt64?, traceDirectory: String,
                    crashPathKeysFile: String? = nil, role: TraceRing.Role = .app) {
            self.pid = pid
            self.processStartUnixMicros = processStartUnixMicros
            self.traceDirectory = traceDirectory
            self.crashPathKeysFile = crashPathKeysFile
            self.role = role
        }

        /// Whether a file's header names this run: its pid, and its process start when the marker has one.
        func owns(pid: UInt32, processStartUnixMicros start: UInt64) -> Bool {
            pid == self.pid && (processStartUnixMicros.map { $0 == start } ?? true)
        }
    }

    /// What a run's files hold for its crash event.
    public struct Files: Sendable, Equatable {
        /// `crash_key.<name>` tags.
        public var tags: [String: String]
        /// The black box events that may leave the Mac (``TraceBlackBoxUpload/events(_:)``).
        public var blackbox: [TraceBlackBoxUpload.Record]

        public init(tags: [String: String] = [:], blackbox: [TraceBlackBoxUpload.Record] = []) {
            self.tags = tags
            self.blackbox = blackbox
        }
    }

    /// Reads a run's files; `blackBox` false skips the ring.
    public typealias Read = @Sendable (_ blackBox: Bool) -> Files

    private let processStartUnixMicros: UInt64?
    private let readFiles: Read
    private let hangReportsOptIn: @Sendable () -> Bool
    private let scrubber: SentryScrubber
    private let claimed = Atomic<Bool>(false)

    /// The evidence of `run`, read from its files.
    ///
    /// - Parameter hangReportsOptIn: Whether the person agreed to hang reports, asked when the crash event is sent.
    public convenience init(run: Run, hangReportsOptIn: @escaping @Sendable () -> Bool) {
        self.init(processStartUnixMicros: run.processStartUnixMicros, read: { PreviousRunCrashEvidence.read(run, blackBox: $0) },
                  hangReportsOptIn: hangReportsOptIn)
    }

    /// Evidence from `read` (tests and tools).
    ///
    /// - Parameters:
    ///   - processStartUnixMicros: The run's process start; nil takes the first fatal event.
    ///   - read: Reads the run's files, once, for the event that gets them.
    ///   - hangReportsOptIn: Whether `blackbox.txt` may go.
    ///   - scrubber: The scrubber `blackbox.txt` goes through.
    public init(processStartUnixMicros: UInt64?, read: @escaping Read, hangReportsOptIn: @escaping @Sendable () -> Bool,
                scrubber: SentryScrubber = SentryScrubber()) {
        self.processStartUnixMicros = processStartUnixMicros
        readFiles = read
        self.hangReportsOptIn = hangReportsOptIn
        self.scrubber = scrubber
    }

    /// Whether an event has had the evidence (it goes to one event only).
    public var isUsed: Bool { claimed.load(ordering: .acquiring) }

    /// `beforeSend` for every event: the run's crash event gets the tags and, with the opt-in, `blackbox.txt` in
    /// `hint`'s attachments; any other event, and every event after it, is left as it is.
    public func decorate(_ event: Event, hint: Hint) {
        guard event.level == .fatal, isTheRunsCrash(event), !isUsed,
              claimed.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { return }
        let optIn = hangReportsOptIn()
        let files = readFiles(optIn)
        if !files.tags.isEmpty {
            var tags = event.tags ?? [:]
            for (key, value) in files.tags where tags[key] == nil { tags[key] = value }
            event.tags = tags
        }
        if let attachment = CrashReporter.blackboxAttachment(files.blackbox, hangReportsOptIn: optIn, scrubber: scrubber) {
            hint.attachments.append(attachment)
        }
    }

    /// The event happened in the run: SentryCrash stamps a crash in whole seconds, so it counts from the second the
    /// run started in.
    private func isTheRunsCrash(_ event: Event) -> Bool {
        guard let start = processStartUnixMicros, start != 0, let time = event.timestamp else { return true }
        return time.timeIntervalSince1970 >= Double(start / 1_000_000)
    }

    /// Reads `run`'s crash-key page, its crash path's line and, with `blackBox`, its black box. Blocking file work.
    public static func read(_ run: Run, blackBox: Bool) -> Files {
        let directory = run.traceDirectory + "/"
        let page = CrashKeyPage.read(atPath: directory + CrashKeyPage.fileName(role: run.role, pid: run.pid))
            .flatMap { run.owns(pid: $0.identity.pid, processStartUnixMicros: $0.identity.processStartUnixMicros) ? $0 : nil }
        let crashPath = run.crashPathKeysFile
            .flatMap { try? String(blockingContentsOfFile: $0, encoding: .utf8) }
            .flatMap { CrashKeys(record: $0) }
        var tags = page?.tags ?? [:]
        tags.merge(crashPath?.tags ?? [:]) { pageValue, _ in pageValue }
        guard blackBox else { return Files(tags: tags) }
        let ring = (try? Data(blockingContentsOf: URL(filePath: directory + TraceRingFile.fileName(role: run.role, pid: run.pid))))
            .flatMap { TraceRing.Image(bytes: [UInt8]($0)) }
            .flatMap { run.owns(pid: $0.header.pid, processStartUnixMicros: $0.header.processStartUnixMicros) ? $0 : nil }
        let events = ring.map { TraceBlackBoxUpload().events(TraceBlackBoxUpload.records(of: $0)) } ?? []
        return Files(tags: tags, blackbox: events)
    }
}
