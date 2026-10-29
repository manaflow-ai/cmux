import CmuxNextCompat
import CmuxNextHangReports
import CmuxNextTrace
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// The forwarder sends the crash reports of the terminal host and holder copies the
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
    /// Another build's image.
    static let otherUUID = "8a1b2c3d-4e5f-3a6b-9c7d-8e9f0a1b2c3d"
    static let otherBytes: [UInt8] = [0x8A, 0x1B, 0x2C, 0x3D, 0x4E, 0x5F, 0x3A, 0x6B, 0x9C, 0x7D, 0x8E, 0x9F, 0x0A, 0x1B, 0x2C, 0x3D]
    static let incident = "0B8D4A51-6C9E-4F0F-8F53-3C2D7B4F9E20"
    static let pid: UInt32 = 4_242
    /// The process start the planted files' headers name (2023-11-14 22:13:20 UTC) and the report's `procLaunch`
    /// for it, as macOS writes it in local time.
    static let start: UInt64 = 1_700_000_000_000_000
    static let procLaunch = "2023-11-14 14:13:20.0000 -0800"

    static var roots: SystemCrashReport.HelperRoots {
        SystemCrashReport.HelperRoots(bundlePath: bundle, mainExecutable: mainExecutable, hostExeRoot: hostExeRoot)
    }

    /// A crash report (bug type 309) of the binary at `path` (written as macOS writes it, the user as `USER`).
    static func ips(path: String, pid: UInt32 = pid, uuid: String = uuid, procLaunch: String? = procLaunch) throws -> Data {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let header: [String: Any] = ["bug_type": "309", "name": name, "incident_id": incident]
        var body: [String: Any] = [
            "procName": name, "procPath": path, "pid": Int(pid), "incident": incident,
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"],
            "faultingThread": 0,
            "threads": [["triggered": true, "frames": [["imageOffset": 777, "imageIndex": 0]]]],
            "usedImages": [["uuid": uuid, "base": 4_294_967_296, "size": 16_777_216, "path": path, "name": name, "arch": "arm64"]],
        ]
        if let procLaunch { body["procLaunch"] = procLaunch }
        var data = try JSONSerialization.data(withJSONObject: header)
        data.append(UInt8(ascii: "\n"))
        data.append(try JSONSerialization.data(withJSONObject: body))
        return data
    }

    static func report(path: String, pid: UInt32 = pid, uuid: String = uuid,
                       procLaunch: String? = procLaunch) throws -> SystemCrashReport {
        try #require(SystemCrashReport(data: try ips(path: path, pid: pid, uuid: uuid, procLaunch: procLaunch)))
    }

    // MARK: - Roots

    @Test func theHostExeCopiesOfTheHostsAndTheHolderAreForwarded() throws {
        for name in ["cmux-holder", "cmux-tui-host", "cmux-tui"] {
            let report = try Self.report(path: "/Users/USER/Library/Application Support/cmux-tui/host-exe/\(Self.sha)/\(name)")
            #expect(report.helperOrigin(in: Self.roots) == .hostExe, "\(name)")
            #expect(report.pid == Int32(Self.pid))
            #expect(report.mainImageUUID == Self.uuid)
            #expect(report.processStartUnixMicros == Self.start)
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
        // Word 9 is the build version's second word: never a tag.
        try Self.keyPage(role: 3, requestMethod: 1_234, terminalCount: 4, holderLink: 2, inFlight: [1_234, 99],
                         untracked: 1, extra: [9: 77])
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
                         "crash_key.holder_link": "lost", "crash_key.requests_in_flight": "3"],
                "two named requests and one past the table; word 9 is not a key")
        #expect(event.eventID == Self.incident.replacingOccurrences(of: "-", with: "").lowercased(),
                "a report forwarded again is the same event")
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

    /// Every cmux app on the Mac (stable, nightly, each tagged DEV build) shares the host-exe root: a copy whose image
    /// this app never ran is another app's daemon's, and goes out only with that app's consent and release.
    @Test func anotherAppsHostExeCopyIsNotForwarded() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.plantRing(.holder, pid: Self.pid, buildUUID: Self.otherBytes, in: fixture.traceFolder)
        let log = CaptureLog()
        let forwarder = fixture.forwarder(log: log, optIn: true, release: "cmux-next@1.1+101")
        let now = Date()
        forwarder.forwardNew(now: now)
        try fixture.writeReport("other.ips", try Self.ips(path: fixture.copyPath("cmux-holder"), uuid: Self.otherUUID),
                                modified: now + 10)
        try fixture.writeReport("own.ips", try Self.ips(path: fixture.copyPath("cmux-tui-host"), pid: Self.pid + 1),
                                modified: now + 11)
        #expect(forwarder.forwardNew(now: now + 20).map(\.lastPathComponent) == ["own.ips"])
        let captured = log.entries()
        try #require(captured.count == 1)
        #expect(captured[0].tags["process_build"] == "this")
        #expect(captured[0].release == "cmux-next@1.1+101")

        try fixture.writeReport("other-later.ips", try Self.ips(path: fixture.copyPath("cmux-holder"), uuid: Self.otherUUID),
                                modified: now + 30)
        #expect(forwarder.forwardNew(now: now + 40).isEmpty, "another app's report is done, never sent")
        let noBinaries = fixture.forwarder(log: log, optIn: true, ownRustBinaries: [], state: "state-empty.json")
        noBinaries.forwardNew(now: now + 45)
        try fixture.writeReport("own-later.ips", try Self.ips(path: fixture.copyPath("cmux-holder")), modified: now + 50)
        #expect(noBinaries.forwardNew(now: now + 60).isEmpty, "an app that ran no image of the copy's sends none")
        #expect(log.entries().count == 1)
    }

    /// Holders and hosts keep running the copy an earlier build made after an app update (pty-holder.md), and that
    /// build is gone: the next launch knows the copy's image from the earlier launch's state and forwards its crash
    /// with its ring and keys, tagged as the earlier build's and with that build's release.
    @Test func anEarlierLaunchsCopyIsForwardedWithItsRelease() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let log = CaptureLog()
        let now = Date()
        fixture.forwarder(log: log, optIn: true, release: "cmux-next@1.0+100").forwardNew(now: now)
        // The update: this app's binaries are a new build now.
        for binary in SystemCrashForwarder.rustBinaries(in: [fixture.bin]) {
            try Data(Self.machO(uuid: Self.otherBytes)).write(to: binary)
        }
        try Self.plantRing(.holder, pid: Self.pid, buildUUID: Self.uuidBytes, in: fixture.traceFolder)
        try Self.keyPage(role: 3, terminalCount: 2, extra: [8: Self.word("0.0.9")])
            .write(to: fixture.traceFolder.appending(path: "holder-\(Self.pid).crashkeys"))
        let updated = fixture.forwarder(log: log, optIn: true, release: "cmux-next@1.1+101")
        try fixture.writeReport("earlier.ips", try Self.ips(path: fixture.copyPath("cmux-holder")), modified: now + 10)
        try fixture.writeReport("new.ips", try Self.ips(path: fixture.copyPath("cmux-tui-host"), pid: Self.pid + 1,
                                                        uuid: Self.otherUUID), modified: now + 11)
        #expect(updated.forwardNew(now: now + 20).map(\.lastPathComponent) == ["earlier.ips", "new.ips"])
        let captured = log.entries()
        try #require(captured.count == 2)
        #expect(captured[0].tags["process_build"] == "other")
        #expect(captured[0].release == "cmux-next@1.0+100", "the earlier build's release, not the one that sends")
        #expect(captured[0].tags["process_build_version"] == "0.0.9")
        #expect(captured[0].tags["process_role"] == "holder")
        #expect(captured[0].tags["crash_key.terminal_count"] == "2")
        #expect(captured[0].attachments.map(\.name) == ["blackbox.txt"])
        #expect(captured[1].tags["process_build"] == "this")
        #expect(captured[1].release == "cmux-next@1.1+101")
    }

    @Test func theOwnImageListKeepsTheNewestLaunches() {
        var state = SystemCrashForwarder.State(watermark: 0, sentAtWatermark: [])
        let first = MachOImageUUIDs(uuids: [Self.uuidBytes])
        let added = state.remember(first, release: "a")
        let again = state.remember(first, release: "a")
        #expect(added)
        #expect(!again, "the same launch again changes nothing")
        #expect(state.ownImage(Self.uuid)?.release == "a")
        let newRelease = state.remember(first, release: "b")
        #expect(newRelease)
        #expect(state.ownImages?.count == 1, "one entry per image, with the newest launch's release")
        #expect(state.ownImage(Self.uuid)?.release == "b")
        for index in 0 ..< SystemCrashForwarder.maxOwnImages {
            _ = state.remember(MachOImageUUIDs(uuids: [[UInt8](repeating: UInt8(index), count: 16)]), release: "c")
        }
        #expect(state.ownImages?.count == SystemCrashForwarder.maxOwnImages)
        #expect(state.ownImage(Self.uuid) == nil, "the oldest image goes first")
        #expect(state.ownImage(nil) == nil)
    }

    @Test func theOwnBinariesAreTheBundlesAndADevDaemonsFolder() {
        let bin = URL(filePath: Self.bundle + "/Contents/Resources/bin", directoryHint: .isDirectory)
        let bundled = SystemCrashForwarder.ownRustBinaries(bundledBin: bin, daemonOverride: nil).map(\.lastPathComponent)
        #expect(bundled == ["cmux-holder", "cmux-tui", "cmux-tui-host"])
        let dev = SystemCrashForwarder.ownRustBinaries(bundledBin: bin, daemonOverride: "/work/target/debug/cmux-tui-dev")
            .map { $0.path(percentEncoded: false) }
        #expect(dev.prefix(4) == ["/work/target/debug/cmux-tui-dev", "/work/target/debug/cmux-holder",
                                  "/work/target/debug/cmux-tui", "/work/target/debug/cmux-tui-host"])
        #expect(dev.count == 7)
        #expect(SystemCrashForwarder.ownRustBinaries(bundledBin: nil, daemonOverride: "").isEmpty)
    }

    @Test func aRingOfAnotherBuildOrWithoutTheOptInIsNotAttached() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.plantRing(.terminalHost, pid: Self.pid, buildUUID: Self.uuidBytes, in: fixture.traceFolder)
        try Self.keyPage(role: 4, terminalCount: 8)
            .write(to: fixture.traceFolder.appending(path: "terminal-host-\(Self.pid).crashkeys"))
        let report = try Self.report(path: fixture.copyPath("cmux-tui-host"))
        let idleKeys = ["crash_key.terminal_count": "8", "crash_key.holder_link": "never",
                        "crash_key.requests_in_flight": "0"]

        let on = fixture.artifacts(optIn: true).extras(for: report)
        #expect(on.processRole == "terminal-host")
        #expect(on.blackbox == "1000 terminal-host holder.spawn I 7 0\n")
        #expect(on.crashKeys == idleKeys, "no request ran: no request_method")

        let off = fixture.artifacts(optIn: false).extras(for: report)
        #expect(off.blackbox == nil, "the black box leaves only with the hang-reports opt-in")
        #expect(off.crashKeys == idleKeys, "crash keys are numbers and always go")

        let otherBuild = try Self.report(path: fixture.copyPath("cmux-tui-host"), uuid: "8a1b2c3d-4e5f-3a6b-9c7d-8e9f0a1b2c3d")
        #expect(fixture.artifacts(optIn: true).extras(for: otherBuild) == SystemCrashEvent.Extras(),
                "a reused pid or another build never lends its files")
        let otherPID = try Self.report(path: fixture.copyPath("cmux-tui-host"), pid: Self.pid + 1)
        #expect(fixture.artifacts(optIn: true).extras(for: otherPID) == SystemCrashEvent.Extras())
    }

    /// The setting turned off with a file edit while cmux was not running leaves the consent record: the launch's
    /// first forwarder pass must not take it for an opt-in. Only the hang-reports controller's decision that reports
    /// are on, with the record still there, lets the black box go.
    @Test func aConsentRecordWithTheSettingOffAttachesNoBlackBox() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.plantRing(.holder, pid: Self.pid, buildUUID: Self.uuidBytes, in: fixture.traceFolder)
        let recorded = ConsentRecord()
        let consent = RustBlackBoxConsent(consentRecorded: { recorded.exists.load(ordering: .relaxed) })
        let artifacts = RustCrashArtifacts(directories: [fixture.traceFolder], blackboxOptIn: { consent.allows })
        let report = try Self.report(path: fixture.copyPath("cmux-holder"))

        #expect(artifacts.extras(for: report).processRole == "holder", "the ring is found")
        #expect(artifacts.extras(for: report).blackbox == nil, "no decision yet: no black box")
        #expect(consent.decide(false), "the first decision starts the forwarder")
        #expect(artifacts.extras(for: report).blackbox == nil, "a consent record with reports off sends nothing")
        #expect(!consent.decide(true), "a later decision does not start it again")
        #expect(artifacts.extras(for: report).blackbox == "1000 holder holder.spawn I 7 0\n")
        recorded.exists.store(false, ordering: .relaxed)
        #expect(artifacts.extras(for: report).blackbox == nil, "the record removed while cmux runs")
    }

    /// The report is read at the next launch, maybe hours later: a later process of the same build and role that
    /// got the crashed pid has rewritten `<role>-<pid>.*` by then. Its files name another start and lend nothing;
    /// a report or header with no start lends nothing either.
    @Test func aLaterProcessGivenTheSamePidNeverLendsItsFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let later = Self.start + 3_600_000_000
        try Self.plantRing(.terminalHost, pid: Self.pid, buildUUID: Self.uuidBytes, start: later, in: fixture.traceFolder)
        try Self.keyPage(role: 4, start: later, terminalCount: 8)
            .write(to: fixture.traceFolder.appending(path: "terminal-host-\(Self.pid).crashkeys"))
        let artifacts = fixture.artifacts(optIn: true)
        let crashed = try Self.report(path: fixture.copyPath("cmux-tui-host"))
        #expect(artifacts.extras(for: crashed) == SystemCrashEvent.Extras(), "same pid, role and UUID, another start")

        let laterReport = try Self.report(path: fixture.copyPath("cmux-tui-host"), procLaunch: "2023-11-14 15:13:20.0050 -0800")
        #expect(artifacts.extras(for: laterReport).processRole == "terminal-host", "within the tolerance: that process's files")

        let noStart = try Self.report(path: fixture.copyPath("cmux-tui-host"), procLaunch: nil)
        #expect(artifacts.extras(for: noStart) == SystemCrashEvent.Extras())

        let unknownFolder = fixture.root.appending(path: "unknown-start")
        try Self.plantRing(.terminalHost, pid: Self.pid, buildUUID: Self.uuidBytes, start: 0, in: unknownFolder)
        try Self.keyPage(role: 4, start: 0).write(to: unknownFolder.appending(path: "terminal-host-\(Self.pid).crashkeys"))
        let unknown = RustCrashArtifacts(directories: [unknownFolder], blackboxOptIn: { true })
        #expect(unknown.extras(for: crashed) == SystemCrashEvent.Extras(), "a header with no start names no process")
    }

    /// With the key-flow knob on, the daemon and its holders write their black boxes in the flows folder: the
    /// crash forwarder reads the same folder list as hang reports (`RingFolders`).
    @Test func aRingInTheKeyFlowFolderIsFound() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let flows = fixture.root.appending(path: "flows", directoryHint: .isDirectory)
        try Self.plantRing(.holder, pid: Self.pid, buildUUID: Self.uuidBytes, in: flows)
        let home = fixture.root.appending(path: "home", directoryHint: .isDirectory)
        let rings = HangReportFieldSources.RingFolders.app(bundleID: "com.cmuxterm.app.next.test", flowsDirectory: flows,
                                                           uid: 501, home: home)
        #expect(rings.directories.last == flows)
        // The fixture's socket folder, not this Mac's /tmp/cmux-hd-501.
        let artifacts = RustCrashArtifacts(directories: rings.directories, holderSockets: fixture.holderSockets,
                                           blackboxOptIn: { true })
        let extras = artifacts.extras(for: try Self.report(path: fixture.copyPath("cmux-holder")))
        #expect(extras.processRole == "holder")
        #expect(extras.blackbox == "1000 holder holder.spawn I 7 0\n")
    }

    @Test func procLaunchIsReadAsUnixMicroseconds() {
        #expect(SystemCrashReport.unixMicros(procLaunch: Self.procLaunch) == Self.start)
        #expect(SystemCrashReport.unixMicros(procLaunch: "2023-11-14 22:13:20.0000 +0000") == Self.start)
        #expect(SystemCrashReport.unixMicros(procLaunch: "2023-11-15 03:43:20.1234 +0530") == Self.start + 123_400)
        #expect(SystemCrashReport.unixMicros(procLaunch: "2024-02-29 00:00:00 +0000") == 1_709_164_800_000_000)
        #expect(SystemCrashReport.unixMicros(procLaunch: "2023-11-14 22:13:20.123456789 +0000") == Self.start + 123_456)
        for bad in ["", "2023-11-14 22:13:20.0000", "2023-13-14 22:13:20.0000 +0000", "2023-11-14 22:13:20.x +0000",
                    "1969-12-31 23:59:59.0000 +0000", "2023-11-14T22:13:20 +0000", "2023-11-14 22:13:20.0000 0000"] {
            #expect(SystemCrashReport.unixMicros(procLaunch: bad) == nil, "\(bad)")
        }
    }

    /// cmux-app-host is a bundle binary (task 095 gives it a black box and a crash-key page): its forwarded crash
    /// carries both.
    @Test func aBundleAppHostCrashCarriesItsRingAndKeys() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Self.plantRing(.appHost, pid: Self.pid, buildUUID: Self.uuidBytes, in: fixture.traceFolder)
        try Self.keyPage(role: 9, requestMethod: 5, inFlight: [5])
            .write(to: fixture.traceFolder.appending(path: "app-host-\(Self.pid).crashkeys"))
        let log = CaptureLog()
        let forwarder = fixture.forwarder(log: log, optIn: true)
        let now = Date()
        forwarder.forwardNew(now: now)
        try fixture.writeReport("app-host.ips", try Self.ips(path: Self.bundle + "/Contents/Resources/bin/cmux-app-host"),
                                modified: now + 10)
        #expect(forwarder.forwardNew(now: now + 20).map(\.lastPathComponent) == ["app-host.ips"])
        let event = try #require(log.entries().first)
        #expect(event.tags["process_origin"] == "bundle")
        #expect(event.tags["process_role"] == "app-host")
        #expect(event.tags["crash_key.request_method"] == "5")
        #expect(event.tags["crash_key.requests_in_flight"] == "1")
        #expect(event.attachments.map(\.name) == ["blackbox.txt"])
        let text = String(decoding: try #require(event.attachments.first).data, as: UTF8.self)
        #expect(text == "1000 app-host holder.spawn I 7 0\n")
    }

    /// The page task 098's encoder left (cmux-trace `crash_keys_page_decodes_after_an_abort_inside_a_scope`, at
    /// 629d914c5fd / d1b5045af3a: a daemon that aborted in request 0xDEADBEEFCAFE with two terminals and its
    /// holder link lost), word for word.
    @Test func thePageTheRustEncoderWroteDecodes() throws {
        let written: [Int: UInt64] = [
            0: 0x5359_454B_4358_4D43, 1: 0x0000_0002_0000_0001, 2: 0x0000_0000_0011_619D, 3: 0x0006_5ECC_7071_F600,
            4: 0xD27E_4DEE_5005_189D, 5: 0x3537_C043_2EAD_FD07, 8: 0x0000_0030_2E31_2E30, 12: 0x0000_DEAD_BEEF_CAFE,
            13: 0x0000_0000_0000_0002, 14: 0x0000_0000_0000_0002, 16: 0x0000_DEAD_BEEF_CAFE,
        ]
        let page = try #require(RustCrashKeyPage(bytes: Self.bytes(of: written)))
        #expect(page.role == TraceRing.Role.daemon.rawValue)
        #expect(page.pid == 1_139_101)
        #expect(page.buildUUID == RustCrashArtifacts.uuidBytes("9d180550-ee4d-7ed2-07fd-ad2e43c03735"))
        #expect(page.processStartUnixMicros == 0x0006_5ECC_7071_F600)
        #expect(page.buildVersion == "0.1.0")
        #expect(page.tags == ["crash_key.request_method": String(UInt64(0xDEAD_BEEF_CAFE)), "crash_key.terminal_count": "2",
                              "crash_key.holder_link": "lost", "crash_key.requests_in_flight": "1"])
    }

    @Test func aDamagedKeyPageGivesNoTags() {
        var page = Self.keyPage(role: 3, terminalCount: 4, holderLink: 9)
        #expect(RustCrashKeyPage(bytes: [UInt8](page))?.tags == ["crash_key.terminal_count": "4", "crash_key.holder_link": "9",
                                                                 "crash_key.requests_in_flight": "0"],
                "a holder link this build does not know goes as its code")
        page[8] = 2
        #expect(RustCrashKeyPage(bytes: [UInt8](page)) == nil, "another version")
        page[8] = 1
        page[0] ^= 0xFF
        #expect(RustCrashKeyPage(bytes: [UInt8](page)) == nil, "wrong magic")
        #expect(RustCrashKeyPage(bytes: [UInt8](Self.keyPage(role: 3, extra: [8: Self.word("0.1/..")])))?.buildVersion == nil,
                "a version with other characters is not a tag")
        #expect(RustCrashKeyPage(bytes: [UInt8](Self.keyPage(role: 3).prefix(4_000))) == nil, "short page")
    }

    @Test func imageUUIDsComeFromThinAndUniversalFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let other = try #require(RustCrashArtifacts.uuidBytes("8a1b2c3d-4e5f-3a6b-9c7d-8e9f0a1b2c3d"))
        let thin = fixture.root.appending(path: "thin")
        let universal = fixture.root.appending(path: "universal")
        let text = fixture.root.appending(path: "text")
        try Data(Self.machO(uuid: Self.uuidBytes)).write(to: thin)
        try Self.universal([Self.machO(uuid: Self.uuidBytes), Self.machO(uuid: other)]).write(to: universal)
        try Data("#!/bin/sh\n".utf8).write(to: text)
        #expect(MachOImageUUIDs(files: [thin]).uuids == [Self.uuidBytes])
        #expect(MachOImageUUIDs(files: [universal]).uuids == [Self.uuidBytes, other])
        #expect(MachOImageUUIDs(files: [text, fixture.root.appending(path: "missing")]).uuids.isEmpty)
        #expect(MachOImageUUIDs(files: [thin]).contains(Self.uuid))
        #expect(!MachOImageUUIDs(files: [thin]).contains("8a1b2c3d-4e5f-3a6b-9c7d-8e9f0a1b2c3d"))
        #expect(!MachOImageUUIDs(files: [thin]).contains(nil))
    }

    // MARK: - Fixtures

    /// A ring of `role` in process `pid` in `folder`, as cmux-trace's `init_blackbox` leaves it: one kept record
    /// (`holder.spawn`), a key record and a per-key PTY hop.
    static func plantRing(_ role: TraceRuntime.Role, pid: UInt32, buildUUID: [UInt8], start: UInt64 = start,
                          in folder: URL) throws {
        let daemonBit = UInt8(6)
        let keyBit = UInt8(1)
        let blackBox = TraceBlackBox(
            role: role, directory: folder.path(percentEncoded: false), runtime: TraceRuntime(role: role),
            process: TraceBlackBox.ProcessFacts(pid: pid, processStartUnixMicros: start, buildUUID: buildUUID),
            catalog: TraceRing.nameTable(names: [(id: 1, category: daemonBit, text: "holder.spawn"),
                                                 (id: 2, category: keyBit, text: "key.echo.host_pty_read"),
                                                 (id: 3, category: daemonBit, text: "holder.pty.read")],
                                         categories: [(bit: keyBit, text: "key"), (bit: daemonBit, text: "daemon")]))
        blackBox.ring.write(name: 1, phase: .instant, timestamp: 1_000, arg0: 7)
        blackBox.ring.write(name: 2, phase: .instant, timestamp: 1_001, arg0: 65)
        blackBox.ring.write(name: 3, phase: .instant, timestamp: 1_002, arg0: 1)
        _ = try #require(blackBox.adoptFile())
    }

    /// A crash-key page as cmux-trace `crash_keys.rs` (task 098) writes it for process ``pid`` with role code
    /// `role`: the header (magic `CMXCKEYS`, version 1 and the role, pid, `LC_UUID` in words 4-5), then the keys
    /// at words 12-14, the untracked count at 15 and the in-flight table from 16. `extra` sets any other word.
    static func keyPage(role: UInt16, pid: UInt32 = pid, uuid: [UInt8] = uuidBytes, start: UInt64 = start,
                        requestMethod: UInt64 = 0,
                        terminalCount: UInt64 = 0, holderLink: UInt64 = 0, inFlight: [UInt64] = [], untracked: UInt64 = 0,
                        extra: [Int: UInt64] = [:]) -> Data {
        func word(_ bytes: ArraySlice<UInt8>) -> UInt64 {
            bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        }
        var words: [Int: UInt64] = [
            0: 0x5359_454B_4358_4D43, // "CMXCKEYS"
            1: 1 | UInt64(role) << 32,
            2: UInt64(pid),
            3: start,
            4: word(uuid[0 ..< 8]),
            5: word(uuid[8 ..< 16]),
            12: requestMethod, 13: terminalCount, 14: holderLink, 15: untracked,
        ]
        for (index, method) in inFlight.enumerated() { words[16 + index] = method }
        for (index, value) in extra { words[index] = value }
        return Data(bytes(of: words))
    }

    /// Up to 8 ASCII bytes as one little-endian word, NUL-padded.
    static func word(_ text: String) -> UInt64 {
        text.utf8.prefix(8).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    /// 512 little-endian words, `words[index]` at each index it names and 0 elsewhere.
    static func bytes(of words: [Int: UInt64]) -> [UInt8] {
        (0 ..< 512).flatMap { index in
            let word = words[index] ?? 0
            return (0 ..< 8).map { UInt8(truncatingIfNeeded: word >> (8 * UInt64($0))) }
        }
    }

    /// A thin arm64 Mach-O image whose load commands are a 72-byte segment and `LC_UUID` `uuid`.
    static func machO(uuid: [UInt8]) -> [UInt8] {
        func le(_ value: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) } }
        let segment = le(0x19) + le(72) + [UInt8](repeating: 0, count: 64)
        let uuidCommand = le(0x1B) + le(24) + uuid
        let header = le(0xFEED_FACF) + le(0x0100_000C) + le(0) + le(2) + le(2)
            + le(UInt32(segment.count + uuidCommand.count)) + le(0) + le(0)
        return header + segment + uuidCommand
    }

    /// A universal file (`FAT_MAGIC`) of `slices`, each at a 4 KiB boundary.
    static func universal(_ slices: [[UInt8]]) -> Data {
        func be(_ value: UInt32) -> [UInt8] { (0 ..< 4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32(3 - $0))) } }
        var bytes = be(0xCAFE_BABE) + be(UInt32(slices.count))
        for (index, slice) in slices.enumerated() {
            bytes += be(0x0100_000C) + be(0) + be(UInt32(4_096 * (index + 1))) + be(UInt32(slice.count)) + be(12)
        }
        for (index, slice) in slices.enumerated() {
            bytes += [UInt8](repeating: 0, count: 4_096 * (index + 1) - bytes.count)
            bytes += slice
        }
        return Data(bytes)
    }

    /// A temporary reports folder, host-exe root, trace folder, holder socket folder and this app's `bin`.
    struct Fixture {
        let root: URL
        var reports: URL { root.appending(path: "DiagnosticReports") }
        var hostExe: URL { root.appending(path: "host-exe") }
        var traceFolder: URL { root.appending(path: "trace") }
        var holderSockets: URL { root.appending(path: "cmux-hd-501") }
        var bin: URL { root.appending(path: "bin") }

        /// The folders, and this app's Rust binaries in `bin`, all with image ``uuid``.
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "system-crash-\(UUID().uuidString)")
            for folder in [reports, hostExe, traceFolder, holderSockets, bin] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            for binary in SystemCrashForwarder.rustBinaries(in: [bin]) {
                try Data(SystemCrashReportTests.machO(uuid: SystemCrashReportTests.uuidBytes)).write(to: binary)
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

        func forwarder(log: CaptureLog, optIn: Bool, ownRustBinaries: [URL]? = nil, release: String? = nil,
                       state: String = "state.json") -> SystemCrashForwarder {
            SystemCrashForwarder(directory: reports, stateFile: root.appending(path: state),
                                 bundlePath: SystemCrashReportTests.bundle, mainExecutable: SystemCrashReportTests.mainExecutable,
                                 hostExeRoot: hostExe.path(percentEncoded: false),
                                 ownRustBinaries: ownRustBinaries ?? SystemCrashForwarder.rustBinaries(in: [bin]),
                                 release: release, artifacts: artifacts(optIn: optIn),
                                 capture: { event, attachments in
                                     log.append(event, attachments.map { Captured.File(name: $0.filename, data: $0.data ?? Data()) })
                                 })
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
        var release: String?
        var eventID: String
        var attachments: [File]
    }

    /// This Mac's consent record, as the forwarder's queue reads it.
    final class ConsentRecord: Sendable {
        let exists = Atomic<Bool>(true)
    }

    final class CaptureLog: Sendable {
        private let captured = Mutex<[Captured]>([])

        /// `attachments` are the event's Sentry attachments as values (the caller maps them: in this file
        /// `Attachment` alone is ambiguous between Sentry's and Swift Testing's).
        func append(_ event: Event, _ attachments: [Captured.File]) {
            let entry = Captured(tags: event.tags ?? [:], release: event.releaseName, eventID: event.eventId.sentryIdString,
                                 attachments: attachments)
            captured.withLock { $0.append(entry) }
        }

        func entries() -> [Captured] {
            captured.withLock { $0 }
        }
    }
}
