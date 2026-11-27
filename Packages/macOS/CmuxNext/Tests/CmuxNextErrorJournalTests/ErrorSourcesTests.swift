@testable import CmuxNextErrorJournal
import Foundation
import Testing

/// The harvest sources read only what is new and map it to events.
struct ErrorSourcesTests {
    private let directory: URL = {
        let url = FileManager().temporaryDirectory.appendingPathComponent("error-sources-\(UUID().uuidString)")
        try? FileManager().createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func append(_ text: String, to url: URL) throws {
        if !FileManager().fileExists(atPath: url.path) { try Data().write(to: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func aLogSourceReadsLevelsAndPanicsOnlyOnce() async throws {
        let log = directory.appendingPathComponent("daemon.log")
        try append("""
        2026-10-17T03:34:21.050714Z  INFO startup complete; agents may spawn
        2026-10-17T10:05:20.627500Z  \u{1b}[33mWARN\u{1b}[0m model catalog refresh: the catalog server answered 404
        2026-10-19T01:21:15.000000Z ERROR pooled session failed to start: agent host did not answer hello within 5s
        thread 'tokio-rt-worker' panicked at library/core/src/slice/sort/shared/smallsort.rs:860:5:
        user-provided comparison function does not correctly implement a total order

        """, to: log)
        let source = LogFileErrorSource(url: log, source: "acpmux")
        let first = try await source.collect(after: nil)
        #expect(first.events.map(\.level) == [.warning, .error, .fault])
        #expect(first.events[0].message == "model catalog refresh: the catalog server answered 404")
        #expect(first.events[2].message == "panic: user-provided comparison function does not correctly implement a total order")
        #expect(first.events[2].topFrame == "library/core/src/slice/sort/shared/smallsort.rs:860")
        let calendar = Calendar(identifier: .gregorian)
        #expect(calendar.component(.year, from: first.events[0].date) == 2026)

        let again = try await source.collect(after: first.cursor)
        #expect(again.events.isEmpty)

        try append("2026-10-19T02:00:00Z  WARN half a line", to: log)
        let partial = try await source.collect(after: first.cursor)
        #expect(partial.events.isEmpty)
        try append(" now done\n", to: log)
        let done = try await source.collect(after: partial.cursor)
        #expect(done.events.map(\.message) == ["half a line now done"])
    }

    @Test func aReplacedLogStartsOver() async throws {
        let log = directory.appendingPathComponent("host.log")
        try append("ERROR first\n", to: log)
        let source = LogFileErrorSource(url: log, source: "chief")
        let first = try await source.collect(after: nil)
        try FileManager().removeItem(at: log)
        try append("ERROR second\n", to: log)
        let second = try await source.collect(after: first.cursor)
        #expect(second.events.map(\.message) == ["second"])
    }

    @Test func aMissingLogYieldsNothing() async throws {
        let harvest = try await LogFileErrorSource(url: directory.appendingPathComponent("none.log"), source: "x").collect(after: nil)
        #expect(harvest.events.isEmpty)
    }

    @Test func theFirstHarvestReadsOnlyTheTail() async throws {
        let log = directory.appendingPathComponent("big.log")
        try append(String(repeating: "ERROR old line\n", count: 100) + "ERROR newest\n", to: log)
        let harvest = try await LogFileErrorSource(url: log, source: "x", firstReadBytes: 20).collect(after: nil)
        #expect(harvest.events.map(\.message) == ["newest"])
    }

    @Test func pageConsoleLogLinesMapToPageSources() {
        let text = ConsoleErrorCapture.logText(level: "warn", message: "theme missing token=abc123secret\nmore",
                                               stack: "Error\n    at load (cmux-page://settings/main.js:4:9)")
        #expect(text.hasPrefix("[warn] theme missing token=<redacted>"))
        let event = OSLogErrorSource.event(subsystem: ConsoleErrorCapture.subsystem, category: "settings", isFault: false,
                                           message: text, date: Date())
        #expect(event.source == "page:settings")
        #expect(event.level == .warning)
        #expect(event.topFrame == "load (cmux-page://settings/main.js:4:9)")
        #expect(OSLogErrorSource.event(subsystem: "com.cmuxterm.app.nightly", category: "acp", isFault: true,
                                       message: "x", date: Date()).source == "app")
        #expect(OSLogErrorSource.event(subsystem: "com.apple.WebKit", category: "Loading", isFault: false,
                                       message: "x", date: Date()).source == "system:com.apple.WebKit")
    }

    @Test func jscStackFramesAreFound() {
        #expect(ConsoleErrorCapture.topFrame("load@cmux-page://home/app.js:10:2\nglobal code") == "load@cmux-page://home/app.js:10:2")
        #expect(ConsoleErrorCapture.topFrame("") == nil)
    }

    @Test func crashReportsBecomeCrashEventsOnce() async throws {
        let report = directory.appendingPathComponent("cmux NIGHTLY-2026-10-18-201500.ips")
        try Data("""
        {"app_name":"cmux NIGHTLY","app_version":"1.0.0","bug_type":"309","incident_id":"X"}
        {"exception" : {"codes":"0x1","type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"threads":[{"frames":[{"symbol":"GhosttySurface.draw"}]}]}
        """.utf8).write(to: report)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("Safari-2026.ips"))
        let source = CrashReportErrorSource(directory: directory)
        let first = try await source.collect(after: nil)
        #expect(first.events.count == 1)
        #expect(first.events.first?.message == "crash cmux NIGHTLY EXC_BAD_ACCESS SIGSEGV")
        #expect(first.events.first?.topFrame == "GhosttySurface.draw")
        #expect(first.events.first?.level == .crash)
        #expect(try await source.collect(after: first.cursor).events.isEmpty)
    }

    @Test func templatesHideValuesButKeepWords() {
        let normalizer = ErrorNormalizer()
        #expect(normalizer.template("session 01a15246-9cfe-7bc2-ad31-c8861e92290d failed in ws_19bb371b at 0x1f") ==
                "session <uuid> failed in <id> at <hex>")
        #expect(normalizer.template("refused \"/tmp/a b\" from https://x.example/a?b=1") == "refused \"<str>\" from <url>")
    }
}
