import CmuxFuzzSupport
import Foundation
import Testing
@testable import CmuxNextErrorJournal

/// The journal reads bytes other programs wrote (`.ips` crash and hang
/// reports, acpmux and Chief logs) and its own files, which a crash or a person can damage
/// (`segment-*.ndjson`, the cursors in `cursors.json`). Any input gives events, nothing, a
/// skipped line or a fresh start; never a trap and never a wait. Seeded property tests on
/// CmuxFuzzSupport (long mode: CMUX_FUZZ_SECONDS; a failure prints its CMUX_FUZZ_SEED and
/// CMUX_FUZZ_ITERATIONS replay).
@Suite struct CrashReportParserFuzzTests {
    /// A crash report (bug type 309) as macOS 15 writes it: a one-line JSON header, then the body.
    static let crashReport = """
    {"app_name":"cmux NEXT Nightly","timestamp":"2026-10-20 10:12:44.00 -0700","app_version":"0.70.0","slice_uuid":"3f0c9e43-7a61-3c8e-9c1a-2b7f5d0e9a11","build_version":"70123","platform":1,"bundleID":"com.cmuxterm.app.nightly","share_with_app_devs":0,"is_first_party":0,"bug_type":"309","os_version":"macOS 15.7.4 (24G517)","name":"cmux NEXT Nightly","incident_id":"0B8D4A51-6C9E-4F0F-8F53-3C2D7B4F9E20"}
    {
      "uptime" : 86000,
      "procRole" : "Foreground",
      "version" : 2,
      "userID" : 501,
      "modelCode" : "Mac16,11",
      "procName" : "cmux NEXT Nightly",
      "exception" : {"codes":"0x0000000000000001, 0x00000001a2b3c4d5","rawCodes":[1,7031866581],"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},
      "termination" : {"flags":0,"code":5,"namespace":"SIGNAL","indicator":"Trace/BPT trap: 5","byProc":"exc handler","byPid":4242},
      "faultingThread" : 0,
      "threads" : [{"triggered":true,"id":123,"queue":"com.apple.main-thread","frames":[{"imageOffset":777,"symbol":"Swift._assertionFailure(_:_:file:line:flags:)","symbolLocation":120,"imageIndex":0},{"imageOffset":12,"symbol":"main","imageIndex":0}]}],
      "usedImages" : [{"source":"P","arch":"arm64","base":4294967296,"size":16777216,"uuid":"3f0c9e43-7a61-3c8e-9c1a-2b7f5d0e9a11","path":"/Applications/cmux NEXT Nightly.app/Contents/MacOS/cmux NEXT Nightly","name":"cmux NEXT Nightly"}]
    }
    """

    /// A hang report (bug type 288): the JSON header, then spindump text.
    static let hangReport = """
    {"app_name":"cmux NEXT Nightly","app_version":"0.70.0","bug_type":"288","os_version":"macOS 26.1 (25B78)","timestamp":"2026-10-21 09:00:00.00 -0700","name":"cmux NEXT Nightly"}
    Date/Time:        2026-10-21 09:00:00.000 -0700
    Duration:         6.12s
    Steps:            61 (100ms sampling interval)
    Process:          cmux NEXT Nightly [4242]
    Thread 0x1a2b    61 samples (1-61)    priority 47 (base 47)
      61  start + 6000 (dyld + 25544) [0x18f1a2b48]
        61  main + 12 (cmux NEXT Nightly + 777) [0x100000309]
    """

    /// acpmux and Chief log lines: tracing levels, ANSI colors and a two-line Rust panic.
    static let log = """
    2026-10-17T03:34:21.050714Z  INFO startup complete; agents may spawn
    2026-10-17T10:05:20.627500Z  \u{1b}[33mWARN\u{1b}[0m model catalog refresh: the catalog server answered 404
    2026-10-19T01:21:15.000000Z ERROR pooled session failed to start: agent host did not answer hello within 5s
    thread 'tokio-rt-worker' panicked at library/core/src/slice/sort/shared/smallsort.rs:860:5:
    user-provided comparison function does not correctly implement a total order
    FATAL the end

    """

    /// Saved cursors a crash or an edit can leave: numbers out of range, NaN, signs, separators.
    static let cursorSeeds = [
        "", "nan", "inf", "-inf", "1e400", "-1e300", "1e300", "1792800000000", "-5", "12:34", "12:-5", "12:",
        ":5", "18446744073709551615:9223372036854775807", "18446744073709551616:1", "1:2:3", "0x10:0x20",
    ]

    static let cursorAlphabet = Array("0123456789-+.eEinfINFaNx: ")
    static let textAlphabet: [Character] = [
        "a", "Z", "0", "9", " ", "\t", "\n", "\r\n", "/", "~", ":", "=", "\"", "'", "?", "&", "@", ".", "_", "-",
        "é", "e\u{301}", "🙂", "👩‍💻", "\u{1b}", "[", "m", "\u{0}", "\u{FFFD}", "W", "A", "R", "N", "E", "O",
    ]

    static let reportMutator = FuzzMutator(dictionary: [
        "{", "}", "[", "]", ":", ",", "\"", "\n", "\"bug_type\"", "\"309\"", "\"288\"", "\"211\"", "\"app_name\"",
        "\"app_version\"", "\"exception\"", "\"type\"", "\"signal\"", "\"symbol\"", "null", "true", "1e999", "\u{0}",
    ].map { Data($0.utf8) })

    static let logMutator = FuzzMutator(dictionary: [
        "WARN", "WARNING", "ERROR", "FATAL", "CRITICAL", "panicked at ", "src/main.rs:12:5:", "\n", "\r\n",
        "\u{1b}[33m", "\u{1b}[", ":", " ", "2026-10-19T01:21:15.000000Z", "9999-99-99T99:99:99Z",
    ].map { Data($0.utf8) })

    static let segmentMutator = FuzzMutator(dictionary: [
        "{", "}", "\n", ",", ":", "\"fp\"", "\"count\"", "\"first_ms\"", "\"last_ms\"", "\"level\"", "\"ctx\"",
        "\"crash\"", "18446744073709551615", "-9223372036854775808", "9223372036854775807", "\"\"", "null",
    ].map { Data($0.utf8) })

    /// A scratch folder of this process's runs.
    static var scratch: URL {
        FileManager().temporaryDirectory.appendingPathComponent(
            "crash-report-fuzz-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true
        )
    }

    /// One input of a parser, its choices read from `data` (the libFuzzer entry).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        let directory = scratch
        try FileManager().createDirectory(at: directory, withIntermediateDirectories: true)
        switch rng.below(5) {
        case 0:
            let input = mutated([Data(crashReport.utf8), Data(hangReport.utf8)], reportMutator, &rng)
            try reportEvent(input, at: directory.appendingPathComponent("cmux-one-input.ips"))
        case 1: try logEvents(String(decoding: mutated([Data(log.utf8)], logMutator, &rng), as: UTF8.self))
        case 2:
            let fixture = try CursorFixture(in: directory.appendingPathComponent("cursor", isDirectory: true))
            try cursor(cursorText(&rng, inode: fixture.inode), fixture)
        case 3: try segmentLoad(mutated([try segment()], segmentMutator, &rng), in: directory.appendingPathComponent("journal"))
        default: try message(rng.text(textAlphabet, 600), limit: rng.below(80), ErrorRedactor(), ErrorNormalizer(maxBytes: 64))
        }
    }

    /// A seed after one mutation pass, or random bytes one time in eight.
    static func mutated(_ seeds: [Data], _ mutator: FuzzMutator, _ rng: inout FuzzRNG) -> Data {
        guard !rng.oneIn(8), let base = rng.element(of: seeds) else { return rng.bytes(512) }
        return mutator.mutate(base, using: &rng)
    }

    /// A seed or random cursor text, half the time behind the fixture log's inode so the log
    /// source takes its saved offset instead of starting over.
    static func cursorText(_ rng: inout FuzzRNG, inode: UInt64) -> String {
        let text = (rng.bool() ? rng.element(of: cursorSeeds) : nil) ?? rng.text(cursorAlphabet, 40)
        return rng.bool() ? "\(inode):\(text)" : text
    }

    /// A reports folder holding one report, and a log, for the cursor runs to harvest.
    struct CursorFixture {
        let reports: URL
        let log: URL
        let inode: UInt64
        let logSize: Int

        init(in directory: URL) throws {
            let files = FileManager()
            reports = directory.appendingPathComponent("reports", isDirectory: true)
            log = directory.appendingPathComponent("daemon.log")
            if !files.fileExists(atPath: log.path) {
                try files.createDirectory(at: reports, withIntermediateDirectories: true)
                try Data(CrashReportParserFuzzTests.crashReport.utf8).write(to: reports.appendingPathComponent("cmux-cursor.ips"))
                try Data(CrashReportParserFuzzTests.log.utf8).write(to: log)
            }
            let attributes = try files.attributesOfItem(atPath: log.path)
            guard let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                  let size = (attributes[.size] as? NSNumber)?.intValue else { throw CocoaError(.fileReadUnknown) }
            self.inode = inode
            logSize = size
        }
    }

    /// A report file's event: whatever its bytes, one crash-level `crash` event that names the
    /// report and keeps the file's date.
    static func reportEvent(_ bytes: Data, at url: URL) throws {
        try bytes.write(to: url)
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        let event = CrashReportErrorSource.event(report: url, modified: modified)
        try FuzzRun.check(event.source == "crash" && event.level == .crash, "a report is a crash event")
        try FuzzRun.check(event.context["report"] == url.path, "the event names its report")
        try FuzzRun.check(event.date == modified && !event.message.isEmpty, "the event keeps the file date and says what it is")
    }

    /// Log text: at most one event per line, never a crash level, always the log's source and file.
    static func logEvents(_ text: String) throws {
        let events = LogLineParser(source: "acpmux", file: "daemon.log").events(in: text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        try FuzzRun.check(events.count <= lines, "\(events.count) events from \(lines) lines")
        for event in events {
            try FuzzRun.check(event.level != .crash, "a log line is never a crash")
            try FuzzRun.check(event.source == "acpmux" && event.context == ["file": "daemon.log"], "an event names its log")
        }
    }

    /// A saved cursor, however damaged, drives both harvests to a cursor the next harvest takes:
    /// whole milliseconds no later than now for the crash source, an offset inside the file
    /// for the log source.
    static func cursor(_ text: String, _ fixture: CursorFixture) throws {
        let crashes = CrashReportErrorSource(directory: fixture.reports).harvest(after: text)
        let saved = crashes.cursor ?? ""
        try FuzzRun.check(Int64(saved) != nil && CrashReportErrorSource.cursorDate(saved, now: Date()) != nil,
                          "cursor \(text.debugDescription) saved \(saved.debugDescription)")
        let lines = try LogFileErrorSource(url: fixture.log, source: "acpmux").harvest(after: text)
        let parts = (lines.cursor ?? "").split(separator: ":", omittingEmptySubsequences: false)
        let offset = parts.count == 2 && UInt64(parts[0]) == fixture.inode ? Int(parts[1]) : nil
        try FuzzRun.check(offset.map { (0...fixture.logSize).contains($0) } == true,
                          "cursor \(text.debugDescription) saved \(String(describing: lines.cursor))")
    }

    /// A journal folder whose only segment holds `bytes`: opening it reads what decodes and skips the rest.
    static func segmentLoad(_ bytes: Data, in directory: URL) throws {
        let files = FileManager()
        if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: directory.appendingPathComponent("segment-000001.ndjson"))
        _ = ErrorJournal(directory: directory)
    }

    /// Message text: redaction and templates take any text, and a prefix stays inside its bound.
    static func message(_ text: String, limit: Int, _ redactor: ErrorRedactor, _ normalizer: ErrorNormalizer) throws {
        let template = normalizer.template(redactor.redact(text))
        try FuzzRun.check(template.utf8.count <= 64 + "…".utf8.count, "a template of \(template.utf8.count) bytes")
        let prefix = text.utf8Prefix(limit)
        try FuzzRun.check(prefix.utf8.count <= limit + "…".utf8.count, "a \(limit)-byte prefix of \(prefix.utf8.count) bytes")
    }

    /// Two entries as the store writes them (sorted keys, one per line).
    static func segment() throws -> Data {
        let entries = [
            ErrorEntry(fingerprint: "00a1b2c3d4e5f607", source: "crash", level: .crash, template: "crash cmux NEXT Nightly",
                       sample: "crash cmux NEXT Nightly EXC_BREAKPOINT SIGTRAP", topFrame: "main",
                       context: ["report": "/tmp/cmux.ips", "version": "0.70.0"], count: 3,
                       firstMs: 1_800_000_000_000, lastMs: 1_800_000_500_000),
            ErrorEntry(fingerprint: "ffeeddccbbaa9988", source: "acpmux", level: .warning, template: "took <n> ms",
                       sample: "took 512 ms", topFrame: nil, context: [:], count: UInt64.max,
                       firstMs: Int64.min, lastMs: Int64.max),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }

    private func runDirectory(_ name: String) throws -> URL {
        let url = Self.scratch.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager().createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Known answers

    @Test func theSampleReportsParse() throws {
        let directory = try runDirectory("samples")
        let crash = directory.appendingPathComponent("cmux-crash.ips")
        try Data(Self.crashReport.utf8).write(to: crash)
        let crashEvent = CrashReportErrorSource.event(report: crash, modified: Date())
        #expect(crashEvent.message == "crash cmux NEXT Nightly EXC_BREAKPOINT SIGTRAP")
        #expect(crashEvent.topFrame == "Swift._assertionFailure(_:_:file:line:flags:)")
        #expect(crashEvent.context["version"] == "0.70.0")
        let hang = directory.appendingPathComponent("cmux-hang.ips")
        try Data(Self.hangReport.utf8).write(to: hang)
        #expect(CrashReportErrorSource.event(report: hang, modified: Date()).message == "hang cmux NEXT Nightly")
        #expect(LogLineParser(source: "acpmux", file: "daemon.log").events(in: Self.log).map(\.level)
            == [.warning, .error, .fault, .fault])
    }

    /// The clock window of a saved cursor: up to a minute ahead and a year back is resumed from;
    /// anything else starts over, and a report dated past now waits for its date.
    @Test func aCursorOutsideTheClockWindowStartsOver() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ms = { (date: Date) in String(Int64(date.timeIntervalSince1970 * 1000)) }
        #expect(CrashReportErrorSource.cursorDate(ms(now.addingTimeInterval(59)), now: now) != nil)
        #expect(CrashReportErrorSource.cursorDate(ms(now.addingTimeInterval(-364 * 86400)), now: now) != nil)
        #expect(CrashReportErrorSource.cursorDate(ms(now.addingTimeInterval(61)), now: now) == nil)
        #expect(CrashReportErrorSource.cursorDate(ms(now.addingTimeInterval(-366 * 86400)), now: now) == nil)
        let directory = try runDirectory("clock")
        let report = directory.appendingPathComponent("cmux-ahead.ips")
        try Data(Self.crashReport.utf8).write(to: report)
        try FileManager().setAttributes([.modificationDate: now.addingTimeInterval(3600)], ofItemAtPath: report.path)
        let before = CrashReportErrorSource(directory: directory, now: { now }).harvest(after: nil)
        #expect(before.events.isEmpty)
        let after = CrashReportErrorSource(directory: directory, now: { now.addingTimeInterval(7200) })
            .harvest(after: before.cursor)
        #expect(after.events.map { $0.context["report"] } == [report.path])
    }

    // MARK: - Seeded runs

    @Test func reportsGiveOneCrashEventForAnyBytes() throws {
        let url = try runDirectory("ips").appendingPathComponent("cmux-fuzz.ips")
        let run = try FuzzRun("CrashReportParser.ips", seed: 0x2901, iterations: 1_500)
        let seeds = [Data(Self.crashReport.utf8), Data(Self.hangReport.utf8)]
        try run.forEachInput(run.corpus(seeds: seeds), mutator: Self.reportMutator) { try Self.reportEvent($0, at: url) }
    }

    @Test func logLinesGiveBoundedEventsForAnyText() throws {
        let run = try FuzzRun("CrashReportParser.log", seed: 0x2902, iterations: 2_000)
        try run.forEachInput(run.corpus(seeds: [Data(Self.log.utf8)]), mutator: Self.logMutator) {
            try Self.logEvents(String(decoding: $0, as: UTF8.self))
        }
    }

    @Test func savedCursorsAlwaysLeadToAUsableCursor() throws {
        let fixture = try CursorFixture(in: runDirectory("cursor"))
        try FuzzRun("CrashReportParser.cursor", seed: 0x2903, iterations: 2_000).forEach { rng in
            try Self.cursor(Self.cursorText(&rng, inode: fixture.inode), fixture)
        }
    }

    @Test func journalSegmentsOpenWhateverTheyHold() throws {
        let directory = try runDirectory("segments")
        let run = try FuzzRun("CrashReportParser.segment", seed: 0x2904, iterations: 300)
        try run.forEachInput(run.corpus(seeds: [Self.segment()]), mutator: Self.segmentMutator) {
            try Self.segmentLoad($0, in: directory)
        }
    }

    @Test func messagesRedactAndShortenForAnyText() throws {
        let redactor = ErrorRedactor()
        let normalizer = ErrorNormalizer(maxBytes: 64)
        try FuzzRun("CrashReportParser.message", seed: 0x2905, iterations: 1_000).forEach { rng in
            try Self.message(rng.text(Self.textAlphabet, 600), limit: rng.below(80), redactor, normalizer)
        }
    }

    @Test func oneInputTakesAnyBytes() throws {
        let run = try FuzzRun("CrashReportParser.oneInput", seed: 0x2906, iterations: 256)
        // Choice tapes: one per branch of `oneInput`; branch 2 also with each cursor seed picked,
        // alone and behind the log's inode.
        let branches: [[UInt8]] = [[0, 1, 0], [0, 1, 1], [1, 1, 0], [2], [3, 1, 0], [4]]
        let cursorTapes: [[UInt8]] = Self.cursorSeeds.indices.flatMap { index -> [[UInt8]] in
            [[2, 1, UInt8(index), 0], [2, 1, UInt8(index), 1]]
        }
        try run.forEachInput(run.corpus(seeds: (branches + cursorTapes).map { Data($0) }), Self.oneInput)
    }
}
