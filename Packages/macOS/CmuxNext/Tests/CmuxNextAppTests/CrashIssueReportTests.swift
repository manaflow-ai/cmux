@testable import CmuxNextApp
import CmuxNextCrashReporting
import Foundation
import Testing

/// The restart notice's Report button gives a report a maintainer can act on:
/// the exception, the faulting address, the crashed thread's named frames,
/// macOS's report file, the uptime, the commit and what the app was doing.
/// Before, it gave only the version, the bundle, macOS, the signal name and
/// "restart after a restart" (2026-10-27, SIGSEGV loop on nightly 4062224162001).
nonisolated struct CrashIssueReportTests {
    static let home = "/Users/someone"
    static let crashUUID = "fe2f08b1-8999-3a3a-90a2-e66c7939dc84"
    static let captured = Date(timeIntervalSince1970: 1_793_160_220.63)

    @Test func aSegfaultReportNamesTheFaultTheThreadTheFramesAndTheContext() throws {
        let report = CrashIssueReport(
            previous: Self.previous(context: Self.context()), version: "1.0.0-nightly.4062224162001 4062224162001",
            bundleID: "com.cmuxterm.app.nightly", osVersion: "Version 27.0 (Build 26A428)",
            commit: "cc0d757245913c0d5c1c7e6b8c481955fe0097ee", system: try Self.system(),
            systemReportName: "cmux-2026-10-27-210342.ips", executableFunction: Self.thisBuild, home: Self.home)
        let body = report.body
        for expected in [
            "- Commit: cc0d757245913c0d5c1c7e6b8c481955fe0097ee",
            "- Exception: EXC_BAD_ACCESS (SIGSEGV), KERN_INVALID_ADDRESS at 0x000000000000001e, codes 0x0000000000000001, 0x000000000000001e",
            "- Crashed thread: 0 (com.apple.main-thread)",
            "- Uptime: 3.0 s",
            "- Restart after a restart: yes",
            "- Open: 2 windows, 5 workspaces, 9 tabs (6 terminal, 2 browser, 1 other)",
            "- Focused pane: browser",
            "- Browser engine: ready, 1 helper failures this run",
            "- Memory: 412 MB footprint, 0.5 s before the crash",
            "- macOS crash report: cmux-2026-10-27-210342.ips",
            "objc_opt_class + 48",
            "swift_task_isMainExecutorImpl + 36",
            "PaneController.focus() + 120",
            "-[NSApplication run] + 628",
            "- workspace.select (key), 1.0 s before the crash",
            "- browser.reload (pointer), 4.0 s before the crash",
        ] {
            #expect(body.contains(expected), "the report lacks \(expected):\n\(body)")
        }
        #expect(!body.contains("Offsets only"), "frames of this build were left unnamed")
        #expect(body.hasSuffix("What were you doing when it happened?\n"))
    }

    @Test func framesOfAnotherBuildKeepTheirOffsetAndNameTheImage() throws {
        let report = CrashIssueReport(previous: Self.previous(context: nil), version: "v", bundleID: "b",
                                      system: try Self.system(), systemReportName: "cmux-x.ips", home: Self.home)
        #expect(report.body.contains("0x1d6a4"), "\(report.body)")
        #expect(report.body.contains("Offsets only (another build, or no symbols): cmux \(Self.crashUUID.uppercased())"))
    }

    @Test func theReportHoldsNoHomePathNoUserNameAndNoURL() throws {
        let report = CrashIssueReport(previous: Self.previous(context: Self.context()), version: "v", bundleID: "b",
                                      system: try Self.system(), systemReportName: "cmux-x.ips",
                                      executableFunction: Self.thisBuild, home: Self.home)
        #expect(!report.body.contains("someone"), "\(report.body)")
        #expect(report.body.contains("~/Library/x.swift"))
        #expect(!report.body.contains("http"))
    }

    @Test func aHugeStackShrinksToAnURLGitHubAccepts() throws {
        var system = try Self.system()
        let frame = SystemCrashReport.Frame(imageIndex: 0, imageOffset: 1, symbol: String(repeating: "generic closure ", count: 20),
                                            symbolLocation: 4)
        system.frames = Array(repeating: frame, count: 200)
        let report = CrashIssueReport(previous: Self.previous(context: Self.context()), version: "v", bundleID: "b",
                                      system: system, systemReportName: "cmux-x.ips", home: Self.home)
        let url = try #require(report.url)
        #expect(url.absoluteString.count <= CrashIssueReport.urlLimit)
        #expect(report.body.contains("- Exception: EXC_BAD_ACCESS"))
    }

    /// An update installed between the crash and the report: the report names the build that
    /// crashed (the 2026-10-27 report said 4059411161803; macOS's report said 4062224162001).
    @Test func aReportAfterAnUpdateNamesTheBuildThatCrashed() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "cmux-\(UUID().uuidString).ips")
        try Self.systemData().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = CrashReportWriter(directory: FileManager.default.temporaryDirectory, bundleID: "com.cmuxterm.app.nightly",
                                       version: "1.0.0-nightly.4059411161803 4059411161803")
        var previous = Self.previous(context: nil)
        previous.version = "1.0.0-nightly.4062224162001 4062224162001"
        previous.commit = "aaaa111"
        let fromMarker = CrashRecoveryService.issueReport(previous: previous, writer: writer, systemLog: file, info: ["CMUXCommit": "bbbb222"])
        #expect(fromMarker.body.contains("- Version: 1.0.0-nightly.4062224162001 4062224162001"), "\(fromMarker.body)")
        #expect(fromMarker.body.contains("- Commit: aaaa111"))
        // A marker from before the fields: macOS's report names the build; the running commit is not it.
        let fromSystem = CrashRecoveryService.issueReport(previous: Self.previous(context: nil), writer: writer, systemLog: file,
                                                          info: ["CMUXCommit": "bbbb222"])
        #expect(fromSystem.body.contains("- Version: 1.0.0-nightly.4062224162001 4062224162001"), "\(fromSystem.body)")
        #expect(fromSystem.body.contains("- Commit: unknown"))
        #expect(fromSystem.body.contains("- Exception: EXC_BAD_ACCESS (SIGSEGV)"))
    }

    /// The context reaches the next launch through `run.json`.
    @Test func theRunMarkerKeepsTheContext() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "crash-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = Self.context()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(Self.previous(context: context)).write(to: directory.appending(path: "run.json"))
        let read = AppRunMarker.readPrevious(marker: directory.appending(path: "run.json"), signal: directory.appending(path: "run.signal"))
        #expect(read?.context == context)
    }

    /// The first action of a burst records at once (a crash right after it still has it); the
    /// rest of the burst waits for the interval.
    @MainActor @Test func anActionRecordsAtOnceThenAtMostOncePerInterval() {
        var writes: [CrashContext] = []
        let recorder = CrashContextRecorder(interval: .seconds(60), snapshot: { Self.context() }, write: { writes.append($0) })
        recorder.actionRan()
        #expect(writes.count == 1)
        recorder.actionRan()
        recorder.actionRan()
        #expect(writes.count == 1)
        recorder.stop()
    }

    // MARK: - Fixtures

    /// The executable's names, as the app's symbol map gives them for its own build.
    static let thisBuild: CrashReportDetails.ExecutableFunction = { uuid, offset, _ in
        uuid.lowercased() == Self.crashUUID && offset == 0x1d6a4 ? ("PaneController.focus()", 120) : nil
    }

    static func previous(context: CrashContext?) -> PreviousRun {
        PreviousRun(pid: 4242, launched: captured.addingTimeInterval(-3), recovery: true, survived: false, signal: SIGSEGV,
                    quitting: false, context: context)
    }

    static func context() -> CrashContext {
        CrashContext(updated: captured.addingTimeInterval(-0.5), windows: 2, workspaces: 5,
                     tabKinds: ["pty", "pty", "pty", "pty", "pty", "remote-terminal", "browser", "browser", "conversation"],
                     focusedPane: "browser", browserEngine: "ready", browserFailures: 1, footprintMegabytes: 412,
                     actions: [
                        .init(id: "workspace.select", entrypoint: "key", at: captured.addingTimeInterval(-1)),
                        .init(id: "browser.reload", entrypoint: "pointer", at: captured.addingTimeInterval(-4)),
                     ])
    }

    /// The shape of macOS's report of the 2026-10-27 crash (`cmux-2026-10-27-210342.ips`).
    static func system() throws -> SystemCrashReport {
        try #require(SystemCrashReport(data: try systemData()))
    }

    static func systemData() throws -> Data {
        let header = #"{"app_name":"cmux","app_version":"1.0.0-nightly.4062224162001","build_version":"4062224162001","bug_type":"309","bundleID":"com.cmuxterm.app.nightly","name":"cmux"}"#
        let body: [String: Any] = [
            "procName": "cmux", "procPath": "/Applications/cmux NIGHTLY.app/Contents/MacOS/cmux",
            "procLaunch": "2026-10-27 21:03:37.6504 -0700", "captureTime": "2026-10-27 21:03:40.6300 -0700",
            "incident": "A1B2", "faultingThread": 0,
            "exception": ["codes": "0x0000000000000001, 0x000000000000001e", "rawCodes": [1, 30], "type": "EXC_BAD_ACCESS",
                          "signal": "SIGSEGV", "subtype": "KERN_INVALID_ADDRESS at 0x000000000000001e"],
            "termination": ["indicator": "Segmentation fault: 11"],
            "threads": [[
                "triggered": true, "id": 49_414_313, "queue": "com.apple.main-thread",
                "frames": [
                    ["imageOffset": 108_836, "symbol": "objc_opt_class", "symbolLocation": 48, "imageIndex": 1],
                    ["imageOffset": 39_652, "symbol": "swift_task_isMainExecutorImpl", "symbolLocation": 36, "imageIndex": 2],
                    ["imageOffset": 0x1d6a4, "imageIndex": 0],
                    ["imageOffset": 2_000, "symbol": "-[NSApplication run]", "symbolLocation": 628, "imageIndex": 3],
                    ["imageOffset": 3_000, "symbol": "\(home)/Library/x.swift", "symbolLocation": 1, "imageIndex": 3],
                ],
            ]],
            "usedImages": [
                ["uuid": crashUUID, "base": 4_296_556_544, "size": 116_293_632, "path": "\(home)/Applications/cmux NIGHTLY.app/Contents/MacOS/cmux", "name": "cmux"],
                ["uuid": "11111111-1111-1111-1111-111111111111", "base": 1, "size": 1, "path": "/usr/lib/libobjc.A.dylib", "name": "libobjc.A.dylib"],
                ["uuid": "22222222-2222-2222-2222-222222222222", "base": 2, "size": 1, "path": "/usr/lib/swift/libswift_Concurrency.dylib", "name": "libswift_Concurrency.dylib"],
                ["uuid": "33333333-3333-3333-3333-333333333333", "base": 3, "size": 1, "path": "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", "name": "AppKit"],
            ],
        ]
        var data = Data(header.utf8)
        data.append(UInt8(ascii: "\n"))
        data.append(try JSONSerialization.data(withJSONObject: body))
        return data
    }
}
