import CmuxNextCompat
import CmuxNextHangReports
import CmuxNextTrace
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// p09-observability-097: the forwarder sends the crash reports of the terminal host and holder copies the
/// daemon runs from the host-exe root (dropped before: only bundle paths were helpers), and a forwarded Rust
/// crash carries that pid's black box (`blackbox.txt`, no key records) and crash-key page (tags).
@Suite struct SystemCrashReportTests {
    static let bundle = "/Applications/cmux NEXT.app"
    static let mainExecutable = bundle + "/Contents/MacOS/cmux NEXT"
    static let hostExeRoot = "/Users/alice/Library/Application Support/cmux-tui/host-exe"
    /// A copy's folder: the binary's SHA-256 as 64 hex digits.
    static let sha = String(repeating: "0f9a", count: 16)
    static let uuid = "3f0c9e43-7a61-3c8e-9c1a-2b7f5d0e9a11"
    static let uuidBytes: [UInt8] = [0x3F, 0x0C, 0x9E, 0x43, 0x7A, 0x61, 0x3C, 0x8E, 0x9C, 0x1A, 0x2B, 0x7F, 0x5D, 0x0E, 0x9A, 0x11]
    static let incident = "0B8D4A51-6C9E-4F0F-8F53-3C2D7B4F9E20"
    static let pid: UInt32 = 4_242

    static var roots: SystemCrashReport.HelperRoots {
        SystemCrashReport.HelperRoots(bundlePath: bundle, mainExecutable: mainExecutable, hostExeRoot: hostExeRoot)
    }

    /// A crash report (bug type 309) of the binary at `path` (written as macOS writes it, the user as `USER`).
    static func ips(path: String, pid: UInt32 = pid, uuid: String = uuid) throws -> Data {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let header: [String: Any] = ["bug_type": "309", "name": name, "incident_id": incident]
        let body: [String: Any] = [
            "procName": name, "procPath": path, "pid": Int(pid), "incident": incident,
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"],
            "faultingThread": 0,
            "threads": [["triggered": true, "frames": [["imageOffset": 777, "imageIndex": 0]]]],
            "usedImages": [["uuid": uuid, "base": 4_294_967_296, "size": 16_777_216, "path": path, "name": name, "arch": "arm64"]],
        ]
        var data = try JSONSerialization.data(withJSONObject: header)
        data.append(UInt8(ascii: "\n"))
        data.append(try JSONSerialization.data(withJSONObject: body))
        return data
    }

    static func report(path: String, pid: UInt32 = pid, uuid: String = uuid) throws -> SystemCrashReport {
        try #require(SystemCrashReport(data: try ips(path: path, pid: pid, uuid: uuid)))
    }

    // MARK: - Roots

    @Test func theHostExeCopiesOfTheHostsAndTheHolderAreForwarded() throws {
        for name in ["cmux-holder", "cmux-tui-host", "cmux-tui"] {
            let report = try Self.report(path: "/Users/USER/Library/Application Support/cmux-tui/host-exe/\(Self.sha)/\(name)")
            #expect(report.helperOrigin(in: Self.roots) == .hostExe, "\(name)")
            #expect(report.pid == Int32(Self.pid))
            #expect(report.mainImageUUID == Self.uuid)
        }
        let helper = try Self.report(path: Self.bundle + "/Contents/Resources/bin/cmux-tui")
        #expect(helper.helperOrigin(in: Self.roots) == .bundle)
    }

    @Test func anUnknownNameAnotherFolderOrTheAppItselfIsNotForwarded() throws {
        let home = "/Users/USER/Library/Application Support"
        let refused = [
            "\(home)/cmux-tui/host-exe/\(Self.sha)/cmux-evil",
            "\(home)/cmux-tui/host-exe/\(Self.sha)/bin/cmux-holder",
            "\(home)/cmux-tui/host-exe/not-a-content-address/cmux-holder",
            "\(home)/cmux-tui/host-exe/\(Self.sha.dropLast(2))/cmux-holder",
            "\(home)/cmux-tui/host-exe/cmux-holder",
            "\(home)/other-app/host-exe/\(Self.sha)/cmux-holder",
            "/Applications/Other.app/Contents/Resources/bin/cmux-holder",
            "/Applications/cmux NEXT.app.old/Contents/Resources/bin/cmux-tui",
            Self.mainExecutable,
        ]
        for path in refused {
            #expect(try Self.report(path: path).helperOrigin(in: Self.roots) == nil, "\(path)")
        }
        let bundleOnly = SystemCrashReport.HelperRoots(bundlePath: Self.bundle, mainExecutable: Self.mainExecutable, hostExeRoot: nil)
        let copy = try Self.report(path: "\(home)/cmux-tui/host-exe/\(Self.sha)/cmux-holder")
        #expect(copy.helperOrigin(in: bundleOnly) == nil)
    }

    @Test func theHostExeRootFollowsTheDaemonsOverride() {
        let home = URL(filePath: "/Users/alice", directoryHint: .isDirectory)
        #expect(SystemCrashReport.HelperRoots.standardHostExeRoot(environment: [:], home: home)
            == "/Users/alice/Library/Application Support/cmux-tui/host-exe")
        #expect(SystemCrashReport.HelperRoots.standardHostExeRoot(environment: ["CMUX_TUI_HOST_EXE_DIR": "/tmp/hx"], home: home)
            == "/tmp/hx")
        #expect(SystemCrashReport.HelperRoots.standardHostExeRoot(environment: ["CMUX_TUI_HOST_EXE_DIR": ""], home: home)
            == "/Users/alice/Library/Application Support/cmux-tui/host-exe")
    }

    // MARK: - Black box and crash keys

    @Test func aPlantedHolderRingGivesOneAttachmentThatPassesThePrivacyScanner() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let holderFolder = fixture.holderSockets.appending(path: "0123456789abcdef.trace")
        try Self.plantRing(.holder, pid: Self.pid, buildUUID: Self.uuidBytes, in: holderFolder)
        try Self.keyPage(role: 3, slots: [8: 1_234, 15: 4, 120: 2, 9: 77])
            .write(to: holderFolder.appending(path: "holder-\(Self.pid).crashkeys"))
        let log = CaptureLog()
        let forwarder = fixture.forwarder(log: log, optIn: true)
        let now = Date()
        #expect(forwarder.forwardNew(now: now).isEmpty, "the first run only sets the watermark")

        try fixture.writeReport("holder.ips", try Self.ips(path: fixture.copyPath("cmux-holder")), modified: now + 10)
        #expect(forwarder.forwardNew(now: now + 20).map(\.lastPathComponent) == ["holder.ips"])

        let captured = log.entries()
        try #require(captured.count == 1)
        let event = captured[0]
        #expect(event.attachments.map(\.name) == ["blackbox.txt"])
        let text = String(decoding: try #require(event.attachments.first).data, as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines == ["1000 holder holder.spawn I 7 0"], "the key record and the per-key PTY hop are dropped")
        let body = try JSONSerialization.data(withJSONObject: ["blackbox": lines])
        #expect(PrivacyLeakScanner(forbiddenTerms: ["alice"]).findings(in: body).isEmpty)

        #expect(event.tags["process"] == "cmux-holder")
        #expect(event.tags["process_origin"] == "host_exe")
        #expect(event.tags["process_role"] == "holder")
        let keys = event.tags.filter { $0.key.hasPrefix("crash_key.") }
        #expect(keys == ["crash_key.request_method": "1234", "crash_key.terminal_count": "4",
                         "crash_key.holder_link_state": "2"],
                "word 9 is not a Rust slot: never a tag")
        #expect(event.eventID == Self.incident.replacingOccurrences(of: "-", with: "").lowercased(),
                "every app that sees the shared copy's report sends the same event id")
    }

    @Test func aReportOfAnUnknownNameUnderTheRootIsNotSent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let log = CaptureLog()
        let forwarder = fixture.forwarder(log: log, optIn: true)
        let now = Date()
        forwarder.forwardNew(now: now)
        try fixture.writeReport("evil.ips", try Self.ips(path: fixture.copyPath("cmux-evil")), modified: now + 10)
        #expect(forwarder.forwardNew(now: now + 20).isEmpty)
        #expect(log.entries().isEmpty)
    }

    @Test func aRingOfAnotherBuildOrWithoutTheOptInIsNotAttached() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.plantRing(.terminalHost, pid: Self.pid, buildUUID: Self.uuidBytes, in: fixture.traceFolder)
        try Self.keyPage(role: 4, slots: [15: 8]).write(to: fixture.traceFolder.appending(path: "terminal-host-\(Self.pid).crashkeys"))
        let report = try Self.report(path: fixture.copyPath("cmux-tui-host"))

        let on = fixture.artifacts(optIn: true).extras(for: report)
        #expect(on.processRole == "terminal-host")
        #expect(on.blackbox == "1000 terminal-host holder.spawn I 7 0\n")
        #expect(on.crashKeys == ["crash_key.terminal_count": "8"])

        let off = fixture.artifacts(optIn: false).extras(for: report)
        #expect(off.blackbox == nil, "the black box leaves only with the hang-reports opt-in")
        #expect(off.crashKeys == ["crash_key.terminal_count": "8"], "crash keys are numbers and always go")

        let otherBuild = try Self.report(path: fixture.copyPath("cmux-tui-host"), uuid: "8a1b2c3d-4e5f-3a6b-9c7d-8e9f0a1b2c3d")
        #expect(fixture.artifacts(optIn: true).extras(for: otherBuild) == SystemCrashEvent.Extras(),
                "a reused pid or another build never lends its files")
        let otherPID = try Self.report(path: fixture.copyPath("cmux-tui-host"), pid: Self.pid + 1)
        #expect(fixture.artifacts(optIn: true).extras(for: otherPID) == SystemCrashEvent.Extras())
    }

    @Test func aDamagedKeyPageGivesNoTags() {
        var page = Self.keyPage(role: 3, slots: [15: 4])
        #expect(RustCrashKeyPage(bytes: [UInt8](page))?.tags == ["crash_key.terminal_count": "4"])
        page[0] ^= 0xFF
        #expect(RustCrashKeyPage(bytes: [UInt8](page)) == nil, "wrong magic")
        #expect(RustCrashKeyPage(bytes: [UInt8](Self.keyPage(role: 3, slots: [:]).prefix(4_000))) == nil, "short page")
    }

    // MARK: - Fixtures

    /// A ring of `role` in process `pid` in `folder`, as cmux-trace's `init_blackbox` leaves it: one kept record
    /// (`holder.spawn`), a key record and a per-key PTY hop.
    static func plantRing(_ role: TraceRuntime.Role, pid: UInt32, buildUUID: [UInt8], in folder: URL) throws {
        let daemonBit = UInt8(6)
        let keyBit = UInt8(1)
        let blackBox = TraceBlackBox(
            role: role, directory: folder.path(percentEncoded: false), runtime: TraceRuntime(role: role),
            process: TraceBlackBox.ProcessFacts(pid: pid, buildUUID: buildUUID),
            catalog: TraceRing.nameTable(names: [(id: 1, category: daemonBit, text: "holder.spawn"),
                                                 (id: 2, category: keyBit, text: "key.echo.host_pty_read"),
                                                 (id: 3, category: daemonBit, text: "holder.pty.read")],
                                         categories: [(bit: keyBit, text: "key"), (bit: daemonBit, text: "daemon")]))
        blackBox.ring.write(name: 1, phase: .instant, timestamp: 1_000, arg0: 7)
        blackBox.ring.write(name: 2, phase: .instant, timestamp: 1_001, arg0: 65)
        blackBox.ring.write(name: 3, phase: .instant, timestamp: 1_002, arg0: 1)
        _ = try #require(blackBox.adoptFile())
    }

    /// A crash-key page in the v1 layout (task 078's header) for process ``pid`` with role code `role`.
    static func keyPage(role: UInt16, slots: [Int: UInt64]) -> Data {
        var words = [UInt64](repeating: 0, count: 512)
        words[0] = 0x3153_5945_4B58_4D43 // "CMXKEYS1"
        words[1] = 1 | 8 << 16 | 512 << 32
        words[2] = UInt64(pid) | UInt64(role) << 32
        words[3] = uuidBytes[0 ..< 8].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        words[4] = uuidBytes[8 ..< 16].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        for (index, value) in slots { words[index] = value }
        return Data(words.flatMap { word in (0 ..< 8).map { UInt8(truncatingIfNeeded: word >> (8 * UInt64($0))) } })
    }

    /// A temporary reports folder, host-exe root, trace folder and holder socket folder.
    struct Fixture {
        let root: URL
        var reports: URL { root.appending(path: "DiagnosticReports") }
        var hostExe: URL { root.appending(path: "host-exe") }
        var traceFolder: URL { root.appending(path: "trace") }
        var holderSockets: URL { root.appending(path: "cmux-hd-501") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "system-crash-\(UUID().uuidString)")
            for folder in [reports, hostExe, traceFolder, holderSockets] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }

        /// The path macOS writes for the copy `name`: under the resolved root (`/private/var/folders`).
        func copyPath(_ name: String) -> String {
            let roots = SystemCrashReport.HelperRoots(bundlePath: SystemCrashReportTests.bundle, mainExecutable: nil,
                                                      hostExeRoot: hostExe.path(percentEncoded: false))
            return (roots.resolvingHostExeRoot().hostExeRoot ?? "") + "/\(SystemCrashReportTests.sha)/\(name)"
        }

        func artifacts(optIn: Bool) -> RustCrashArtifacts {
            RustCrashArtifacts(directories: [traceFolder], holderSockets: holderSockets, blackboxOptIn: { optIn })
        }

        func forwarder(log: CaptureLog, optIn: Bool) -> SystemCrashForwarder {
            SystemCrashForwarder(directory: reports, stateFile: root.appending(path: "state.json"),
                                 bundlePath: SystemCrashReportTests.bundle, mainExecutable: SystemCrashReportTests.mainExecutable,
                                 hostExeRoot: hostExe.path(percentEncoded: false), artifacts: artifacts(optIn: optIn),
                                 capture: { event, attachments in log.append(event, attachments) })
        }

        func writeReport(_ name: String, _ data: Data, modified: Date) throws {
            let url = reports.appending(path: name)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// What the forwarder handed Sentry, as values.
    struct Captured: Sendable {
        struct File: Sendable {
            var name: String
            var data: Data
        }

        var tags: [String: String]
        var eventID: String
        var attachments: [File]
    }

    final class CaptureLog: Sendable {
        private let captured = Mutex<[Captured]>([])

        func append(_ event: Event, _ attachments: [Attachment]) {
            let entry = Captured(tags: event.tags ?? [:], eventID: event.eventId.sentryIdString,
                                 attachments: attachments.map { Captured.File(name: $0.filename, data: $0.data ?? Data()) })
            captured.withLock { $0.append(entry) }
        }

        func entries() -> [Captured] {
            captured.withLock { $0 }
        }
    }
}
