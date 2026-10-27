import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextCrashReporting

/// p09-observability-105: each Crashpad minidump becomes one Sentry upload, redacted, only with consent, and the
/// macOS crash report of the same process is not sent again.
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
            #expect(request.event.tags["app"] == CrashEventLabels.app)
            #expect(request.event.release == "cmux-next@1.0+7")
            #expect(request.event.fingerprint.first == CrashEventLabels.app)
            let body = request.multipartBody(boundary: "b")
            #expect(body.containsText("name=\"upload_file_minidump\""))
            #expect(!body.containsText("planted.example"))
        }
    }

    @Test func withoutConsentDumpsAreDeletedUnsent() throws {
        let scratch = try MinidumpScratch()
        defer { scratch.remove() }
        let dump = try scratch.plant(pid: 501, in: "pending")
        let uploads = RecordingMinidumpUploader(outcome: .accepted)
        let sent = scratch.forwarder(uploader: uploads, mayForward: false).forwardNew(now: scratch.now)
        #expect(uploads.requests.isEmpty)
        #expect(!sent.covers(pid: 501, at: scratch.now))
        #expect(!FileManager.default.fileExists(atPath: dump.path), "a dump from a time reports were off is never sent later")
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
            mayForward: { true }, labels: scratch.labels, uploader: uploads)
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
    func plant(pid: Int32, in folder: String, module: String = MinidumpFixture.homePath) throws -> URL {
        var fixture = MinidumpFixture()
        fixture.pid = pid
        fixture.timeStamp = UInt32(now.timeIntervalSince1970)
        fixture.mainModulePath = module
        let directory = database.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).dmp")
        try fixture.data().write(to: url)
        return url
    }

    func forwarder(uploader: any MinidumpUploading, mayForward: Bool = true) -> ChromiumMinidumpForwarder {
        ChromiumMinidumpForwarder(database: { [database] in database }, stateFile: root.appending(path: "minidumps.json"),
                                  mainExecutableName: "cmux NEXT", mayForward: { mayForward }, labels: labels,
                                  uploader: uploader)
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

/// Counts captured Sentry events.
private final class CapturedEvents: Sendable {
    private let events = Mutex(0)

    var count: Int { events.withLock { $0 } }

    func add() {
        events.withLock { $0 += 1 }
    }
}
