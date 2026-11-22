@testable import CmuxNextCrashReporting
import Foundation
import Sentry
import Synchronization
import Testing

/// cx-urd.58: helper processes (the cmux-tui daemon, acpmux, Chromium
/// helpers) crash outside Sentry's reach; their macOS crash reports reach
/// Sentry once each, symbolicatable, and only for this app's own bundle.
@Suite struct SystemCrashForwarderTests {
    static let bundle = "/Applications/cmux NIGHTLY.app"

    /// A bug-type 309 report like the ones macOS writes (user name already `USER`).
    static func report(process: String, path: String, exception: Bool = false) -> Data {
        let header = #"{"app_name":"\#(process)","bug_type":"309","name":"\#(process)","incident_id":"INC-1"}"#
        let last = exception ? #","lastExceptionBacktrace":[{"imageOffset":64,"imageIndex":1,"symbol":"objc_exception_throw"}]"# : ""
        let body = """
        {"procName":"\(process)","procPath":"\(path)","incident":"INC-1","faultingThread":1,
         "exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},
         "termination":{"indicator":"Segmentation fault: 11"},
         "threads":[{"frames":[]},{"triggered":true,"frames":[
           {"imageOffset":4096,"imageIndex":0},
           {"imageOffset":8192,"imageIndex":0},
           {"imageOffset":32,"imageIndex":1,"symbol":"start"}]}],
         "usedImages":[
           {"uuid":"d9f36be8-d4e2-3e7a-a29c-8b8ba9e6219a","base":4294967296,"size":65536,"arch":"arm64","path":"\(path)","name":"\(process)"},
           {"uuid":"11111111-2222-3333-4444-555555555555","base":6442450944,"size":4096,"arch":"arm64e","path":"/usr/lib/dyld","name":"dyld"}]\(last)}
        """
        return Data((header + "\n" + body).utf8)
    }

    @Test func aReportBecomesASymbolicatableEvent() throws {
        let path = "/Users/USER/Applications/cmux NIGHTLY.app/Contents/Resources/bin/cmux-tui"
        let report = try #require(SystemCrashReport(data: Self.report(process: "cmux-tui", path: path)))
        let event = SystemCrashEvent(report: report).event()
        let crash = try #require(event.exceptions?.last)
        #expect(crash.type == "EXC_BAD_ACCESS")
        #expect(crash.value == "SIGSEGV, Segmentation fault: 11")
        #expect(crash.mechanism?.handled?.boolValue == false)
        let frames = try #require(crash.stacktrace?.frames)
        #expect(frames.map(\.instructionAddress) == ["0x180000020", "0x100002000", "0x100001000"], "outermost first")
        #expect(frames.last?.package == "cmux-tui")
        #expect(event.debugMeta?.map(\.debugID) == ["d9f36be8-d4e2-3e7a-a29c-8b8ba9e6219a", "11111111-2222-3333-4444-555555555555"])
        #expect(event.debugMeta?.first?.imageAddress == "0x100000000")
        #expect(event.debugMeta?.first?.codeFile == "cmux-tui", "file names only, never paths")
        #expect(event.tags?["process"] == "cmux-tui")
    }

    @Test func anObjectiveCThrowStackGoesFirst() throws {
        let report = try #require(SystemCrashReport(data: Self.report(process: "cmux Helper (Renderer)",
                                                                    path: "/x/cmux Helper (Renderer)", exception: true)))
        let event = SystemCrashEvent(report: report).event()
        #expect(event.exceptions?.map(\.type) == ["NSException", "EXC_BAD_ACCESS"])
        #expect(event.exceptions?.first?.stacktrace?.frames.first?.function == "objc_exception_throw")
    }

    @Test func onlyHelpersOfThisBundleCount() throws {
        func helper(_ path: String) throws -> Bool {
            try #require(SystemCrashReport(data: Self.report(process: "p", path: path)))
                .isHelper(ofBundle: "/Users/lawrence/Apps/cmux.app", mainExecutable: "/Users/lawrence/Apps/cmux.app/Contents/MacOS/cmux")
        }
        #expect(try helper("/Users/USER/Apps/cmux.app/Contents/Resources/bin/cmux-tui"))
        #expect(try helper("/Users/USER/Apps/cmux.app/Contents/Frameworks/cmux Helper.app/Contents/MacOS/cmux Helper"))
        #expect(try !helper("/Users/USER/Apps/cmux.app/Contents/MacOS/cmux"), "the app's own crash is Sentry's")
        #expect(try !helper("/Users/USER/Apps/cmux.apple/Contents/Resources/bin/cmux-tui"))
        #expect(try !helper("/Applications/Other.app/Contents/MacOS/Other"))
        #expect(SystemCrashReport.contents(of: Data("{\"bug_type\":\"288\"}\n{}".utf8)) == .other, "not a crash report")
        #expect(SystemCrashReport.contents(of: Data("{\"bug_type\":\"309\"}\n{\"threads\":[".utf8)) == .incomplete)
    }

    /// A scratch reports folder and a forwarder over it that records what it captures.
    final class Fixture: Sendable {
        let root = FileManager.default.temporaryDirectory.appending(path: "crash-forwarder-\(UUID().uuidString)")
        var reports: URL { root.appending(path: "DiagnosticReports") }
        let sent = Collected()

        init() throws {
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func forwarder(sends: Bool = true) -> SystemCrashForwarder {
            let sent = sent
            return SystemCrashForwarder(directory: reports, stateFile: root.appending(path: "state.json"),
                                        bundlePath: SystemCrashForwarderTests.bundle,
                                        mainExecutable: SystemCrashForwarderTests.bundle + "/Contents/MacOS/cmux", sends: sends,
                                        capture: { event in sent.names.withLock { $0.append(event.tags?["process"] ?? "") } })
        }

        func write(_ name: String, _ data: Data, at time: Double) throws {
            let url = reports.appending(path: name)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path)
        }
    }

    static let helperPath = bundle + "/Contents/Resources/bin/cmux-tui"

    @Test func crashesFromATimeReportsWereOffAreNeverSent() throws {
        let fixture = try Fixture()
        #expect(fixture.forwarder(sends: false).forwardNew(now: Date(timeIntervalSince1970: 1_000)).isEmpty)
        try fixture.write("cmux-tui-off.ips", Self.report(process: "cmux-tui", path: Self.helperPath), at: 2_000)
        #expect(fixture.forwarder(sends: false).forwardNew(now: Date(timeIntervalSince1970: 3_000)).isEmpty)
        // Reports turned on at the next launch.
        #expect(fixture.forwarder().forwardNew(now: Date(timeIntervalSince1970: 4_000)).isEmpty)
        #expect(fixture.sent.names.withLock { $0 }.isEmpty)
    }

    @Test func aReportStillBeingWrittenIsRetriedNotLost() throws {
        let fixture = try Fixture()
        let forwarder = fixture.forwarder()
        forwarder.forwardNew(now: Date(timeIntervalSince1970: 1_000))
        let whole = Self.report(process: "cmux-tui", path: Self.helperPath)
        try fixture.write("cmux-tui-a.ips", whole.prefix(whole.count / 2), at: 2_000)
        #expect(forwarder.forwardNew(now: Date(timeIntervalSince1970: 2_010)).isEmpty, "half written, 10 s old: pending")
        try fixture.write("cmux-tui-a.ips", whole, at: 2_000)
        #expect(forwarder.forwardNew(now: Date(timeIntervalSince1970: 2_020)).map(\.lastPathComponent) == ["cmux-tui-a.ips"])
        // A file that never parses stops nothing once it is old.
        try fixture.write("broken.ips", Data("{".utf8), at: 3_000)
        try fixture.write("cmux-tui-b.ips", whole, at: 3_001)
        #expect(forwarder.forwardNew(now: Date(timeIntervalSince1970: 3_100)).map(\.lastPathComponent) == ["cmux-tui-b.ips"])
    }

    @Test func eachNewReportIsSentOnceAndOldReportsNever() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "crash-forwarder-\(UUID().uuidString)")
        let reports = root.appending(path: "DiagnosticReports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helperPath = Self.bundle + "/Contents/Resources/bin/cmux-tui"
        func write(_ name: String, _ data: Data, at time: Double) throws {
            let url = reports.appending(path: name)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path)
        }
        let sent = Collected()
        let forwarder = SystemCrashForwarder(directory: reports, stateFile: root.appending(path: "state.json"),
                                             bundlePath: Self.bundle, mainExecutable: Self.bundle + "/Contents/MacOS/cmux",
                                             capture: { event in sent.names.withLock { $0.append(event.tags?["process"] ?? "") } })

        try write("cmux-tui-old.ips", Self.report(process: "cmux-tui", path: helperPath), at: 1_000)
        #expect(forwarder.forwardNew(now: Date(timeIntervalSince1970: 2_000)).isEmpty, "the first run only sets the watermark")

        try write("cmux-tui-new.ips", Self.report(process: "cmux-tui", path: helperPath), at: 3_000)
        try write("acpmux-new.ips", Self.report(process: "acpmux", path: Self.bundle + "/Contents/Resources/bin/acpmux"), at: 3_000)
        try write("Other-new.ips", Self.report(process: "Other", path: "/Applications/Other.app/Contents/MacOS/Other"), at: 3_001)
        try write("cmux-new.ips", Self.report(process: "cmux", path: Self.bundle + "/Contents/MacOS/cmux"), at: 3_002)
        try write("notes.txt", Self.report(process: "cmux-tui", path: helperPath), at: 3_003)
        let first = forwarder.forwardNew(now: Date(timeIntervalSince1970: 4_000)).map(\.lastPathComponent)
        #expect(Set(first) == ["cmux-tui-new.ips", "acpmux-new.ips"])
        #expect(forwarder.forwardNew(now: Date(timeIntervalSince1970: 5_000)).isEmpty, "never twice")

        try write("cmux-tui-same-second.ips", Self.report(process: "cmux-tui", path: helperPath), at: 3_002)
        #expect(forwarder.forwardNew(now: Date(timeIntervalSince1970: 6_000)).map(\.lastPathComponent) == ["cmux-tui-same-second.ips"])
        #expect(sent.names.withLock { $0 }.sorted() == ["acpmux", "cmux-tui", "cmux-tui"])
    }
}

/// Events the forwarder captured (a Mutex cannot be captured by an escaping closure itself).
final class Collected: Sendable {
    let names = Mutex<[String]>([])
}
