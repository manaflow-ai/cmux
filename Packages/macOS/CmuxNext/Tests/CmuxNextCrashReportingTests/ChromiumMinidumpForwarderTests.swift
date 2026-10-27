import CmuxNextCompat
import Foundation
import Sentry
import Testing
@testable import CmuxNextCrashReporting

/// p09-observability-105: each Crashpad minidump becomes one Sentry event: the redacted dump with hang report
/// consent, a crash summary without it, nothing with crash reports off; and the macOS crash report of the same
/// process is not sent again.
@Suite struct ChromiumMinidumpForwarderTests {
    @Test func oneUploadPerMinidumpThenTheDumpIsGone() throws {
        let scratch = try MinidumpScratch()
        defer { scratch.remove() }
        let first = try scratch.plant(pid: 501, in: "pending")
        let second = try scratch.plant(pid: 502, in: "completed")
        let uploads = RecordingMinidumpUploader(outcome: .accepted)
        let forwarder = scratch.forwarder(uploader: uploads)
        let sent = forwarder.forwardNew(now: scratch.now)
        #expect(uploads.requests.count == 2)
        #expect(sent.covers(pid: 501, at: scratch.now) && sent.covers(pid: 502, at: scratch.now))
        #expect(!FileManager.default.fileExists(atPath: first.path) && !FileManager.default.fileExists(atPath: second.path))
        forwarder.forwardNew(now: scratch.now)
        #expect(uploads.requests.count == 2, "a dump is sent once")
        for request in uploads.requests {
            #expect(!request.minidump.containsText("planted.example"))
            #expect(request.event.tags["crash_source"] == "crashpad_minidump")
            #expect(request.event.tags["process_type"] == "renderer")
            #expect(request.event.tags["dump_kind"] == "crash")
            #expect(request.event.tags["app"] == CrashEventLabels.app)
            #expect(request.event.level == "fatal")
            #expect(request.event.release == "cmux-next@0.62.0+4711", "the build that crashed, not this launch's")
            #expect(request.event.dist == "4711")
            #expect(request.event.tags["chromium_ver"] == "154.0.8037.98-30")
            #expect(request.event.fingerprint.first == CrashEventLabels.app)
            let body = request.multipartBody(boundary: "b")
            #expect(body.containsText("name=\"upload_file_minidump\""))
            #expect(!body.containsText("planted.example"))
        }
    }

    @Test func withCrashReportsOffDumpsAreDeletedUnsent() throws {
        let scratch = try MinidumpScratch()
        defer { scratch.remove() }
        let dump = try scratch.plant(pid: 501, in: "pending")
        let uploads = RecordingMinidumpUploader(outcome: .accepted)
        let summaries = CapturedSummaries()
        let sent = scratch.forwarder(uploader: uploads, mode: .discard, capture: summaries).forwardNew(now: scratch.now)
        #expect(uploads.requests.isEmpty && summaries.all.isEmpty)
        #expect(!sent.covers(pid: 501, at: scratch.now))
        #expect(!FileManager.default.fileExists(atPath: dump.path), "a dump from a time reports were off is never sent later")
    }

    /// Crash reports on, hang report consent missing (the default): Crashpad took the crash, so macOS wrote no
    /// report; the crash still reaches Sentry once, as a summary like the macOS report's event.
    @Test func withoutHangReportConsentARendererCrashIsStillOneEvent() throws {
        let scratch = try MinidumpScratch()
        defer { scratch.remove() }
        let dump = try scratch.plant(pid: 501, in: "pending")
        let uploads = RecordingMinidumpUploader(outcome: .accepted)
        let summaries = CapturedSummaries()
        let forwarder = scratch.forwarder(uploader: uploads, mode: .summary, capture: summaries)
        let sent = forwarder.forwardNew(now: scratch.now)
        #expect(uploads.requests.isEmpty, "the dump itself leaves the Mac only with consent")
        let summary = try #require(summaries.all.first)
        #expect(summaries.all.count == 1)
        #expect(summary.type == "EXC_BAD_ACCESS")
        #expect(summary.tags["crash_source"] == "crashpad_summary")
        #expect(summary.tags["process_type"] == "renderer")
        #expect(summary.tags["process"] == MinidumpFixture.helperName)
        #expect(summary.release == "cmux-next@0.62.0+4711" && summary.dist == "4711")
        #expect(summary.frames == [SystemCrashEvent.hex(MinidumpFixture.crashLR), SystemCrashEvent.hex(MinidumpFixture.crashPC)])
        #expect(summary.debugIDs == [MinidumpFixture.debugID])
        #expect(sent.covers(pid: 501, at: scratch.now), "a host's macOS report of the same crash is not sent again")
        #expect(!FileManager.default.fileExists(atPath: dump.path))
        forwarder.forwardNew(now: scratch.now)
        #expect(summaries.all.count == 1, "a crash is sent once")
    }

    /// A dump written without a crash (DumpWithoutCrashing, a child HangWatcher report) is never a fatal crash and
    /// its still-running process's pid hides no later crash report.
    @Test func aSimulatedDumpIsAWarningNotACrash() throws {
        let scratch = try MinidumpScratch()
        defer { scratch.remove() }
        try scratch.plant(pid: 501, in: "pending", exceptionCode: ChromiumMinidump.simulatedExceptionCode)
        let uploads = RecordingMinidumpUploader(outcome: .accepted)
        let sent = scratch.forwarder(uploader: uploads).forwardNew(now: scratch.now)
        let request = try #require(uploads.requests.first)
        #expect(request.event.level == "warning")
        #expect(request.event.tags["dump_kind"] == "simulated")
        #expect(!sent.covers(pid: 501, at: scratch.now))

        let summaries = CapturedSummaries()
        let unconsented = try scratch.plant(pid: 502, in: "pending", exceptionCode: ChromiumMinidump.simulatedExceptionCode)
        let summarySent = scratch.forwarder(uploader: uploads, mode: .summary, capture: summaries).forwardNew(now: scratch.now)
        #expect(summaries.all.isEmpty, "no crash, nothing to summarize")
        #expect(!summarySent.covers(pid: 502, at: scratch.now))
        #expect(!FileManager.default.fileExists(atPath: unconsented.path))
    }

    @Test func aDumpFromAnOlderBuildKeepsItsRelease() throws {
        let scratch = try MinidumpScratch()
        defer { scratch.remove() }
        try scratch.plant(pid: 501, in: "pending", ver: "0.61.0+4000 cef150.0.1.2-29")
        try scratch.plant(pid: 502, in: "completed", ver: "150.0.1.2-cef29")
        let uploads = RecordingMinidumpUploader(outcome: .accepted)
        scratch.forwarder(uploader: uploads).forwardNew(now: scratch.now)
        let byVersion = Dictionary(uniqueKeysWithValues: uploads.requests.map { ($0.event.release, $0.event) })
        let older = try #require(byVersion["cmux-next@0.61.0+4000"], "\(byVersion.keys)")
        #expect(older.dist == "4000" && older.tags["chromium_ver"] == "150.0.1.2-29")
        let unnamed = try #require(byVersion[scratch.labels.release], "a dump that names no build gets this launch's release")
        #expect(unnamed.dist == scratch.labels.dist && unnamed.tags["chromium_ver"] == "150.0.1.2-cef29")
    }

    /// Before the hang report controller applies the setting, dumps wait (even with a stale consent record), and
    /// their pids still cover the host's macOS report.
    @Test func dumpsWaitForTheHangReportDecision() throws {
        let scratch = try MinidumpScratch()
        defer { scratch.remove() }
        let dump = try scratch.plant(pid: 501, in: "pending")
        let uploads = RecordingMinidumpUploader(outcome: .accepted)
        let summaries = CapturedSummaries()
        let waiting = scratch.forwarder(uploader: uploads, mode: .wait, capture: summaries).forwardNew(now: scratch.now)
        #expect(uploads.requests.isEmpty && summaries.all.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dump.path))
        #expect(waiting.covers(pid: 501, at: scratch.now))
        scratch.forwarder(uploader: uploads, mode: .summary, capture: summaries).forwardNew(now: scratch.now)
        #expect(summaries.all.count == 1 && uploads.requests.isEmpty, "consent off once decided: a summary")
    }

    @Test func theModeFollowsCrashReportsTheChannelAndTheHangReportDecision() {
        let nightly = Self.policy(bundleID: "com.cmuxterm.app.nightly")
        let stable = Self.policy(bundleID: "com.cmuxterm.app")
        let none: [String: String] = [:]
        let key = "CMUX_NEXT_DEV_HANG_REPORTS"
        typealias Forwarder = ChromiumMinidumpForwarder
        #expect(Forwarder.baseMode(policy: nightly, sends: false, devOptInKey: key, environment: none) == .discard)
        #expect(Forwarder.baseMode(policy: nightly, sends: true, devOptInKey: key, environment: ["CMUX_TEST_PROCESS": "1"]) == .discard)
        #expect(Forwarder.baseMode(policy: stable, sends: true, devOptInKey: key, environment: none) == .summary)
        #expect(Forwarder.baseMode(policy: nightly, sends: true, devOptInKey: key, environment: none) == .upload)
        let consent = Forwarder.Consent()
        let passes = CapturedEvents()
        consent.whenWaitEnds { passes.add() }
        #expect(Forwarder.mode(base: .summary, consent: consent.decisionForPass()) == .summary)
        consent.decide(false)
        #expect(passes.count == 0, "a summary pass never waited, so the decision runs no pass")
        let fresh = Forwarder.Consent()
        fresh.whenWaitEnds { passes.add() }
        #expect(Forwarder.mode(base: .upload, consent: fresh.decisionForPass()) == .wait)
        fresh.decide(true)
        #expect(passes.count == 1, "the decision a pass waited for runs one more pass")
        #expect(Forwarder.mode(base: .upload, consent: fresh.decisionForPass()) == .upload)
        fresh.decide(false)
        #expect(passes.count == 1)
        #expect(Forwarder.mode(base: .upload, consent: fresh.decisionForPass()) == .summary, "hang reports turned off")
    }

    @Test func aFailedUploadIsRetriedAndTheAppsOwnDumpIsNotSent() throws {
        let scratch = try MinidumpScratch()
        defer { scratch.remove() }
        let dump = try scratch.plant(pid: 501, in: "pending")
        let own = try scratch.plant(pid: 77, in: "pending", module: "/Applications/cmux NEXT.app/Contents/MacOS/cmux NEXT")
        let failing = RecordingMinidumpUploader(outcome: .retryLater)
        scratch.forwarder(uploader: failing).forwardNew(now: scratch.now)
        #expect(failing.requests.count == 1, "the app's own crash is Sentry's, never a minidump upload")
        #expect(FileManager.default.fileExists(atPath: dump.path), "kept for the next launch")
        #expect(!FileManager.default.fileExists(atPath: own.path))
        let working = RecordingMinidumpUploader(outcome: .accepted)
        scratch.forwarder(uploader: working).forwardNew(now: scratch.now)
        #expect(working.requests.count == 1)
        #expect(!FileManager.default.fileExists(atPath: dump.path))
    }

    @Test func noCrashpadDatabaseSendsNothing() throws {
        let scratch = try MinidumpScratch()
        defer { scratch.remove() }
        try scratch.plant(pid: 501, in: "pending")
        let uploads = RecordingMinidumpUploader(outcome: .accepted)
        let forwarder = ChromiumMinidumpForwarder(
            database: { nil }, stateFile: scratch.root.appending(path: "state.json"), mainExecutableName: "cmux NEXT",
            mode: { .upload }, labels: scratch.labels, uploader: uploads, capture: { _ in })
        #expect(forwarder.forwardNew(now: scratch.now).entries.isEmpty)
        #expect(uploads.requests.isEmpty)
    }

    @Test func theMacOSReportOfASentDumpsProcessIsDropped() throws {
        let scratch = try MinidumpScratch()
        defer { scratch.remove() }
        let reports = scratch.root.appending(path: "DiagnosticReports", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let bundle = "/Applications/cmux NEXT.app"
        let systemState = scratch.root.appending(path: "system-state.json")
        let captured = CapturedEvents()
        let uploads = RecordingMinidumpUploader(outcome: .accepted)
        let system = SystemCrashForwarder(directory: reports, stateFile: systemState, bundlePath: bundle,
                                          mainExecutable: bundle + "/Contents/MacOS/cmux NEXT",
                                          minidumps: scratch.forwarder(uploader: uploads), capture: { _ in captured.add() })
        // A run before this one set the watermark: every report written since is new.
        try Data(#"{"watermark": 0, "sentAtWatermark": []}"#.utf8).write(to: systemState)
        try scratch.plant(pid: 601, in: "pending")
        let host = bundle + "/Contents/MacOS/cmux NEXT Chromium Host"
        try Self.ips(pid: 601, path: host).write(to: reports.appending(path: "host-a.ips"))
        try Self.ips(pid: 602, path: host).write(to: reports.appending(path: "host-b.ips"))
        let sent = system.forwardNew(now: scratch.now)
        #expect(uploads.requests.count == 1)
        #expect(captured.count == 1, "pid 601's report is the dump's crash; pid 602's has no dump")
        #expect(sent.map(\.lastPathComponent) == ["host-b.ips"])
    }

    @Test func theMinidumpEndpointIsTheDSNsProject() {
        let endpoint = URLSessionMinidumpUploader.endpoint(dsn: CrashReporter.dsn)
        #expect(endpoint?.absoluteString == "https://o4507547940749312.ingest.us.sentry.io/api/4510796264636416/minidump/"
            + "?sentry_key=ecba1ec90ecaee02a102fba931b6d2b3")
        #expect(URLSessionMinidumpUploader.endpoint(dsn: "http://key@example.com/1") == nil, "https only")
        #expect(MinidumpUploadRequest.safeFileName("a\"\r\nb.dmp") == "ab.dmp")
    }

    /// A macOS crash report (bug type 309) of `pid` at `path`.
    static func ips(pid: Int32, path: String) -> Data {
        let header = #"{"bug_type":"309","name":"cmux NEXT Chromium Host"}"#
        let body = """
        {"pid": \(pid), "procName": "cmux NEXT Chromium Host", "procPath": "\(path)", "faultingThread": 0,
         "exception": {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"},
         "threads": [{"triggered": true, "frames": [{"imageIndex": 0, "imageOffset": 16}]}],
         "usedImages": [{"uuid": "00000000-0000-0000-0000-000000000001", "base": 4096, "size": 4096, "path": "\(path)"}]}
        """
        return Data((header + "\n" + body).utf8)
    }

    static func policy(bundleID: String) -> CrashReportingPolicy {
        CrashReportingPolicy(bundleID: bundleID, shortVersion: "1.0", build: "7", isDebugBuild: false, telemetryOptIn: true,
                             managedDisablesTelemetry: false, processEnvironment: [:])
    }
}

/// A Crashpad database in a temporary folder.
private struct MinidumpScratch {
    let root: URL
    /// The dumps' write time, and about the time the macOS reports get from the file system: the same crash.
    let now = Date()
    let labels = ChromiumMinidumpForwarder.Labels(release: "cmux-next@1.0+7", dist: "7", environment: "nightly-next",
                                                  tags: ["app": CrashEventLabels.app, "channel": "nightly"])

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "minidumps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var database: URL { root.appending(path: "Chromium", directoryHint: .isDirectory) }

    /// Writes a renderer dump of `pid` into the database's `folder`.
    @discardableResult
    func plant(pid: Int32, in folder: String, module: String = MinidumpFixture.homePath, exceptionCode: UInt32 = 1,
               ver: String? = nil) throws -> URL {
        var fixture = MinidumpFixture()
        fixture.pid = pid
        fixture.timeStamp = UInt32(now.timeIntervalSince1970)
        fixture.mainModulePath = module
        fixture.exceptionCode = exceptionCode
        if let ver { fixture.ver = ver }
        let directory = database.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).dmp")
        try fixture.data().write(to: url)
        return url
    }

    func forwarder(uploader: any MinidumpUploading, mode: ChromiumMinidumpForwarder.Mode = .upload,
                   capture: CapturedSummaries = CapturedSummaries()) -> ChromiumMinidumpForwarder {
        ChromiumMinidumpForwarder(database: { [database] in database }, stateFile: root.appending(path: "minidumps.json"),
                                  mainExecutableName: "cmux NEXT", mode: { mode }, labels: labels, uploader: uploader,
                                  capture: { capture.add($0) })
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Records each upload and answers at once with `outcome`.
private final class RecordingMinidumpUploader: MinidumpUploading {
    private let outcome: MinidumpUploadOutcome
    private let recorded = Mutex<[MinidumpUploadRequest]>([])

    init(outcome: MinidumpUploadOutcome) {
        self.outcome = outcome
    }

    var requests: [MinidumpUploadRequest] { recorded.withLock { $0 } }

    func upload(_ request: MinidumpUploadRequest, completion: @escaping @Sendable (MinidumpUploadOutcome) -> Void) {
        recorded.withLock { $0.append(request) }
        completion(outcome)
    }
}

/// The fields of each captured crash summary event.
private final class CapturedSummaries: Sendable {
    struct Summary: Sendable {
        var type: String?
        var tags: [String: String]
        var release: String?
        var dist: String?
        var frames: [String]
        var debugIDs: [String]
    }

    private let summaries = Mutex<[Summary]>([])

    var all: [Summary] { summaries.withLock { $0 } }

    func add(_ event: Event) {
        let exception = event.exceptions?.first
        let summary = Summary(type: exception?.type, tags: event.tags ?? [:], release: event.releaseName, dist: event.dist,
                              frames: exception?.stacktrace?.frames.compactMap(\.instructionAddress) ?? [],
                              debugIDs: event.debugMeta?.compactMap(\.debugID) ?? [])
        summaries.withLock { $0.append(summary) }
    }
}

/// Counts captured Sentry events.
private final class CapturedEvents: Sendable {
    private let events = Mutex(0)

    var count: Int { events.withLock { $0 } }

    func add() {
        events.withLock { $0 += 1 }
    }
}
