import CmuxNextCompat
import CmuxNextTrace
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// The previous run's crash event, sent at the next launch, gets that run's crash keys as
/// tags and, with the hang-reports opt-in, its black box as `blackbox.txt`, exactly once, with catalog names and
/// numbers only and 0 key records.
@Suite struct PreviousRunCrashEvidenceTests {
    private typealias Record = TraceBlackBoxUpload.Record
    private typealias Name = TraceBlackBoxUpload.Record.Name

    /// The previous run's process start (µs) and the second it falls in.
    private static let start: UInt64 = 1_790_000_000_250_000
    private static let startSecond = TimeInterval(start / 1_000_000)
    private static let action = Name(text: "action.perform", kind: .catalog, categoryBit: 0)
    private static let hang = Name(text: "hang.thread_hung", kind: .catalog, categoryBit: 7)
    /// Records that time a key: catalog key names, PTY hops, the flow-marked present estimate, an interned name.
    private static let keyNames: [Name] = [
        Name(text: "key.frame", kind: .catalog, categoryBit: 1),
        Name(text: "key.echo.host_pty_read", kind: .catalog, categoryBit: 1),
        Name(text: "holder.pty.read", kind: .catalog, categoryBit: 6),
        Name(text: "frame.present_estimate", kind: .catalog, categoryBit: 10),
        Name(text: "terminal.keystroke", kind: .interned, categoryBit: 1),
    ]

    /// 100 key records among 200 action and hang records.
    private static func planted() -> [Record] {
        (0 ..< 300).map { index -> Record in
            let time = UInt64(1_000 + index)
            guard index % 3 != 0 else {
                return Record(process: .app, timestamp: time, name: keyNames[(index / 3) % keyNames.count],
                              phaseCode: TraceRecord.Phase.instant.rawValue, arg0: 42, arg1: 0xF10F)
            }
            return Record(process: .app, timestamp: time, name: index % 2 == 0 ? action : hang,
                          phaseCode: TraceRecord.Phase.begin.rawValue, arg0: 3)
        }
    }

    /// Counts the reads and the black-box flag each one asked with.
    private final class Reads: Sendable {
        let count = Atomic<Int>(0)
        let withBlackBox = Atomic<Int>(0)
    }

    private static func evidence(optIn: Bool = true, reads: Reads = Reads(),
                                 files: PreviousRunCrashEvidence.Files = .init(tags: ["crash_key.daemon_pid": "77"], blackbox: planted()))
        -> PreviousRunCrashEvidence {
        PreviousRunCrashEvidence(processStartUnixMicros: start, read: { blackBox in
            reads.count.add(1, ordering: .relaxed)
            if blackBox { reads.withBlackBox.add(1, ordering: .relaxed) }
            return files
        }, hangReportsOptIn: { optIn })
    }

    private static func event(_ level: SentryLevel = .fatal, at seconds: TimeInterval = startSecond + 5) -> Event {
        let event = Event(level: level)
        event.timestamp = Date(timeIntervalSince1970: seconds)
        return event
    }

    private static func attachmentText(_ hint: Hint) throws -> String {
        let attachment = try #require(hint.attachments.first { $0.filename == CrashReporter.blackboxFileName })
        return String(decoding: try #require(attachment.data), as: UTF8.self)
    }

    @Test("The run's crash event gets the keys and blackbox.txt; a second fatal event gets nothing")
    func attachedExactlyOnce() throws {
        let reads = Reads()
        let evidence = Self.evidence(reads: reads)
        let first = Self.event()
        let firstHint = Hint()
        evidence.decorate(first, hint: firstHint)
        #expect(firstHint.attachments.count == 1)
        #expect(firstHint.attachments.first?.filename == "blackbox.txt")
        #expect(first.tags?["crash_key.daemon_pid"] == "77")
        #expect(evidence.isUsed)

        let second = Self.event(at: Self.startSecond + 9)
        let secondHint = Hint()
        evidence.decorate(second, hint: secondHint)
        #expect(secondHint.attachments.isEmpty)
        #expect(second.tags == nil)
        #expect(reads.count.load(ordering: .relaxed) == 1)
    }

    @Test("blackbox.txt holds only catalog names and numbers, and 0 key records")
    func attachmentPrivacy() throws {
        let hint = Hint()
        Self.evidence().decorate(Self.event(), hint: hint)
        let text = try Self.attachmentText(hint)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 200)
        for name in Self.keyNames { #expect(!text.contains(name.text), "\(name.text)") }
        #expect(!text.contains("pty"))
        for line in lines {
            let fields = line.split(separator: " ")
            #expect(fields.count == 6)
            #expect(fields[2] == "action.perform" || fields[2] == "hang.thread_hung")
            #expect(fields[0].allSatisfy(\.isNumber) && fields[4].allSatisfy(\.isNumber) && fields[5].allSatisfy(\.isNumber))
        }
    }

    @Test("blackbox.txt goes through the scrubber")
    func attachmentIsScrubbed() throws {
        let leak = Record(process: .app, timestamp: 1, name: Name(text: "alice@example.com", kind: .catalog, categoryBit: 0),
                          phaseCode: TraceRecord.Phase.instant.rawValue)
        let hint = Hint()
        Self.evidence(files: .init(blackbox: [leak])).decorate(Self.event(), hint: hint)
        #expect(!(try Self.attachmentText(hint)).contains("alice@example.com"))
    }

    @Test("Without the hang-reports opt-in: the keys, no blackbox.txt, and the ring is not read")
    func noAttachmentWithoutOptIn() {
        let reads = Reads()
        let event = Self.event()
        let hint = Hint()
        Self.evidence(optIn: false, reads: reads).decorate(event, hint: hint)
        #expect(hint.attachments.isEmpty)
        #expect(event.tags?["crash_key.daemon_pid"] == "77")
        #expect(reads.count.load(ordering: .relaxed) == 1)
        #expect(reads.withBlackBox.load(ordering: .relaxed) == 0)
    }

    @Test("A non-fatal event and an older run's crash leave the evidence for the run's crash")
    func onlyTheRunsCrash() throws {
        let reads = Reads()
        let evidence = Self.evidence(reads: reads)
        let warning = Self.event(.error)
        evidence.decorate(warning, hint: Hint())
        let older = Self.event(at: Self.startSecond - 60)
        let olderHint = Hint()
        evidence.decorate(older, hint: olderHint)
        #expect(warning.tags == nil && older.tags == nil && olderHint.attachments.isEmpty)
        #expect(!evidence.isUsed)
        #expect(reads.count.load(ordering: .relaxed) == 0)

        // SentryCrash stamps whole seconds: a crash in the run's first second still is the run's.
        let crash = Self.event(at: Self.startSecond)
        let hint = Hint()
        evidence.decorate(crash, hint: hint)
        #expect(hint.attachments.count == 1)
        #expect(crash.tags?["crash_key.daemon_pid"] == "77")
    }

    @Test("An event's own tag wins over the run's key")
    func eventTagsWin() {
        let event = Self.event()
        event.tags = ["crash_key.daemon_pid": "5"]
        Self.evidence().decorate(event, hint: Hint())
        #expect(event.tags?["crash_key.daemon_pid"] == "5")
    }

    @Test("The files: page and crash-path keys, the ring's uploadable events; another process's files are skipped")
    func readsTheRunsFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "previous-run-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let pid: UInt32 = 4242
        let page = CrashKeyPage(identity: .init(pid: pid, role: .app, processStartUnixMicros: Self.start))
        page.set(.daemonPID, 77)
        page.set(.windowCount, CrashKeyPage.countBucket(3))
        #expect(page.adopt(directory: directory) != nil)
        let ring = TraceRing(sizes: TraceRing.Sizes(nameCapacity: 64, threadCapacity: 256, chunkCount: 64),
                             identity: TraceRing.Identity(pid: pid, role: .app, processStartUnixMicros: Self.start),
                             catalog: [TraceRing.CatalogName(id: 1, kind: 1, category: 0, text: "action.perform"),
                                       TraceRing.CatalogName(id: 2, kind: 1, category: 1, text: "key.frame")])
        for index in 0 ..< 30 { ring.write(name: index % 2 == 0 ? 1 : 2, phase: .instant, timestamp: 100 + UInt64(index)) }
        try Data(ring.image()).write(to: URL(filePath: directory + "/" + TraceRingFile.fileName(role: .app, pid: pid)))
        let crashPathKeys = try #require(CrashKeys(record: "crash_keys daemon_epoch=3\n"))
        let run = PreviousRunCrashEvidence.Run(pid: pid, processStartUnixMicros: Self.start, traceDirectory: directory,
                                               crashPathKeys: crashPathKeys)

        let files = PreviousRunCrashEvidence.read(run, blackBox: true)
        #expect(files.tags["crash_key.daemon_pid"] == "77")
        #expect(files.tags["crash_key.window_count"] == "2")
        #expect(files.tags["crash_key.daemon_epoch"] == "3")
        #expect(files.blackbox.count == 15)
        #expect(files.blackbox.allSatisfy { $0.name?.text == "action.perform" })
        #expect(PreviousRunCrashEvidence.read(run, blackBox: false).blackbox.isEmpty)

        // A reused pid: the files' headers name a process that started at another time.
        var reused = run
        reused.processStartUnixMicros = Self.start + 1
        let other = PreviousRunCrashEvidence.read(reused, blackBox: true)
        #expect(other.tags == ["crash_key.daemon_epoch": "3"])
        #expect(other.blackbox.isEmpty)
    }

    @Test("Sentry's options send every event through the previous run's evidence")
    func optionsDecorate() throws {
        let policy = CrashReportingPolicy(bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
                                          telemetryOptIn: true, managedDisablesTelemetry: false, processEnvironment: [:])
        let options = CrashReporter(policy: policy, previousRun: Self.evidence()).options()
        let beforeSend = try #require(options.beforeSendWithHint)
        let hint = Hint()
        let sent = try #require(beforeSend(Self.event(), hint))
        #expect(sent.tags?["crash_key.daemon_pid"] == "77")
        #expect(hint.attachments.count == 1)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// sentry-cocoa 9 calls only `beforeSendWithHint` when it is set, so the recorder (086) must record there too:
    /// the previous run's crash lands as a file with its crash keys and `blackbox.txt`, and is never sent.
    @Test("The recorder records the previous run's crash with its evidence")
    func recorderKeepsTheEvidence() throws {
        let policy = CrashReportingPolicy(bundleID: "com.cmuxterm.app.nightly", shortVersion: "1.0", build: "42", isDebugBuild: false,
                                          telemetryOptIn: true, managedDisablesTelemetry: false, processEnvironment: [:])
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "sentry-recorder-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SentryRecorderTransport(directory: directory, lane: { $0() })
        let options = CrashReporter(policy: policy, previousRun: Self.evidence(), recorder: recorder).options()
        let beforeSend = try #require(options.beforeSendWithHint)
        #expect(!options.enableAutoSessionTracking)
        let event = Self.event()

        #expect(beforeSend(event, Hint()) == nil, "a recorded event is never sent")

        let file = String(decoding: try Data(contentsOf: recorder.file(eventID: event.eventId.sentryIdString)), as: UTF8.self)
        #expect(file.contains("crash_key.daemon_pid"))
        #expect(file.contains(CrashReporter.blackboxFileName))
    }
    #endif
}
