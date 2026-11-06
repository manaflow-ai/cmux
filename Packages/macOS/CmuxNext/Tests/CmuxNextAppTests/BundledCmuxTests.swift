@testable import CmuxNextCloud
@testable import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// The app's Cloud API calls run through the bundled cmux (`cmux cloud api`; cmux-tui
/// `cli/cloud_api.rs`, which has the routes' own tests). Swift only forwards: the request and the
/// credential go on the child's stdin (never argv), the answer line is decoded as the route's own
/// answer or read as its typed error, and a child that gives no answer is never taken for a refusal.
@Suite(.serialized)
struct BundledCmuxTests {
    @Test func aWriteGoesOnStdinAndTheAnswerDecodesAsTheRoutes() async throws {
        let cmux = try FakeBundledCmux(answer: #"{"ok":true,"body":{"path":"/a","dataBase64":"aGk=","size":2}}"#)
        defer { cmux.remove() }
        let api = cmux.worker()
        let big = Data(repeating: 7, count: 1_000_000)
        try await api.writeFile("vm_abcdefghij0123456789", path: "/a", data: big, mode: 0o640)
        let request = cmux.request(1)
        #expect(request["call"] as? String == "machine.io")
        #expect(request["auth"] as? String == "worker")
        #expect(request["credential"] as? String == "session-access")
        #expect(request["team"] as? String == "team_cmux")
        #expect(request["refresh"] == nil, "the Stack refresh token never goes to the Worker")
        let args = try #require(request["args"] as? [String: Any])
        #expect(args["op"] as? String == "write")
        #expect(args["machine"] as? String == "vm_abcdefghij0123456789")
        #expect(args["mode"] as? Int == 0o640)
        #expect(args["data_base64"] as? String == big.base64EncodedString())
        #expect(args["cache_dir"] as? String == cmux.folder.appendingPathComponent("sessions").path)
        #expect(cmux.argv(1) == "cloud api", "the credential is never in argv")
        let read = try await api.readFile("vm_abcdefghij0123456789", path: "/a")
        #expect(read.dataBase64 == "aGk=")
    }

    @Test func eachErrorKindIsItsCloudAPIError() async throws {
        let cmux = try FakeBundledCmux()
        defer { cmux.remove() }
        let api = cmux.classic()
        let cases: [(String, CloudAPIError)] = [
            (#"{"ok":false,"error":{"kind":"http","status":404,"code":"vm_file_not_found","message":"no such file: /a","action":"Run it.","trace_id":"t-1"}}"#,
             .http(status: 404, code: "vm_file_not_found", message: "no such file: /a", action: "Run it.", traceId: "t-1")),
            (#"{"ok":false,"error":{"kind":"plan_required","message":"Pro.","upgrade_url":"https://cmux.com/pricing","plan":"max"}}"#,
             .planRequired(message: "Pro.", upgradeURL: URL(string: "https://cmux.com/pricing"), plan: "max")),
            (#"{"ok":false,"error":{"kind":"timed_out","path":"/api/runs"}}"#, .timedOut("/api/runs")),
            (#"{"ok":false,"error":{"kind":"transport","message":"offline"}}"#, .transport("offline")),
            (#"{"ok":false,"error":{"kind":"no_backend"}}"#, .noBackend(api.baseURL)),
            (#"{"ok":false,"error":{"kind":"decoding","message":"bad"}}"#, .decoding("bad")),
        ]
        for (line, expected) in cases {
            try cmux.answer(line)
            await #expect(throws: expected) { _ = try await api.snapshots("vm-1") }
        }
        // The classic client's request: the Stack session and the app's team.
        let request = cmux.request(1)
        #expect(request["auth"] as? String == "stack")
        #expect(request["refresh"] as? String == "refresh")
        #expect(request["team"] as? String == "team-1")
        #expect(request["api"] as? String == "https://vm-api.standin.invalid")
    }

    /// A child that printed nothing usable may have run the call: it is `timedOut`, never a refusal.
    @Test func noAnswerIsNeverARefusal() async throws {
        let cmux = try FakeBundledCmux(answer: "not json")
        defer { cmux.remove() }
        await #expect(throws: CloudAPIError.timedOut("machine.io")) {
            try await cmux.worker().makeDirectory("vm_abcdefghij0123456789", path: "/a")
        }
        #expect(cmux.runs == 1, "a change cmux may have made is not sent again")
    }

    @Test func aBuildWithoutTheBundledCmuxSendsNothing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-cmux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let missing = BundledCmux(bundleResources: folder, work: BackgroundWork(), environment: [:])
        let api = CloudAPIClient(configuration: FakeBundledCmux.configuration, tokens: { ("a", "r") }, teamID: { nil }, cli: missing)
        await #expect(throws: CloudAPIError.transport("the bundled cmux did not start")) { _ = try await api.listDomains() }
        let none = CloudAPIClient(configuration: FakeBundledCmux.configuration, tokens: { ("a", "r") }, teamID: { nil }, cli: nil)
        await #expect(throws: CloudAPIError.transport("this build has no bundled cmux")) { _ = try await none.listDomains() }
    }

    @Test func aSignedOutCallRunsNothing() async throws {
        let cmux = try FakeBundledCmux()
        defer { cmux.remove() }
        struct Out: Error {}
        let api = cmux.classic(tokens: { throw Out() })
        await #expect(throws: CloudAPIError.notSignedIn) { _ = try await api.listDomains() }
        #expect(cmux.runs == 0)
    }

    /// The person key goes after the request's line, never in a JSON value; the answer is the new run.
    @Test func aKeyedStartSendsTheKeyBytesAfterTheRequest() async throws {
        let cmux = try FakeBundledCmux(answer: #"{"ok":true,"body":{"personInstance":"run-2"}}"#)
        defer { cmux.remove() }
        let key = Data("person-key-line\n".utf8)
        let instance = try await cmux.owner().acpmuxKeyedStart("vm_abcdefghij0123456789", keyLineLength: key.count) { stream in
            let bytes = [UInt8](key)
            return stream.write(bytes, maxLength: bytes.count) == bytes.count
        }
        #expect(instance == "run-2")
        let stdin = cmux.stdin(1)
        #expect(stdin.suffix(key.count) == key)
        let request = cmux.request(1)
        #expect(request["call"] as? String == "owner.acpmux_keyed_start")
        #expect(request["auth"] as? String == "owner")
        #expect((request["args"] as? [String: Any])?["key_length"] as? Int == key.count)
        #expect(!(String(data: stdin.prefix(stdin.count - key.count), encoding: .utf8) ?? "").contains("person-key"))
    }

    #if DEBUG
    /// The app calls the machine routes from main-actor handlers: the temp file and the answer's read and
    /// parse run off the main thread, so the blocking detector records nothing there.
    @MainActor @Test func aMainActorCallerNeverBlocksTheMainThread() async throws {
        let cmux = try FakeBundledCmux(answer: #"{"ok":true,"body":{"path":"/a","dataBase64":"aGk=","size":2}}"#)
        defer { cmux.remove() }
        let api = cmux.worker()
        let table = BlockingViolationTable(mode: .record)
        let read = try await BlockingViolationTable.$scoped.withValue(table) {
            try await api.readFile("vm_abcdefghij0123456789", path: "/a")
        }
        await table.flush()
        #expect(read.dataBase64 == "aGk=")
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }

    /// The Cloud service makes its runner on the main thread at start: that makes no file system call.
    @MainActor @Test func makingTheAppsRunnerTouchesNoFileOnTheMainThread() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-cmux-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let table = BlockingViolationTable(mode: .record)
        let cli = BlockingViolationTable.$scoped.withValue(table) {
            BundledCmux(bundleResources: folder, work: BackgroundWork(), environment: [:])
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty)
        #expect(cli?.binary.path == folder.appendingPathComponent("bin/cmux").path)
    }
    #endif

    /// Every file call of a run runs on the app's blocking-work lanes (`BackgroundWork` `.files`), never on
    /// the cooperative pool. With the lanes shut down (quit refuses new items), a run's temp file is refused,
    /// so no file is touched and the child never starts.
    @Test func theFileCallsRunOnTheAppsFileLane() async throws {
        let cmux = try FakeBundledCmux()
        defer { cmux.remove() }
        let closed = BackgroundWork()
        await closed.shutdown()
        let cli = BundledCmux(binary: cmux.cli.binary, work: closed)
        await #expect(throws: CancellationError.self, "the answer's temp file") {
            _ = try await cli.line(["cloud", "api"], stdin: Data("{}".utf8), timeout: .seconds(10))
        }
        #expect(cmux.runs == 0, "the child never started")
    }

    /// A child past its deadline is killed and answers no line.
    @Test func aChildPastItsDeadlineIsKilled() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bundled-cmux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = folder.appendingPathComponent("cmux")
        try Data("#!/bin/sh\nexec sleep 30\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let start = ContinuousClock.now
        do {
            _ = try await BundledCmux(binary: binary, work: BackgroundWork()).line(["x"], stdin: Data(), timeout: .milliseconds(300))
            Issue.record("expected no answer")
        } catch let noAnswer as BundledCmux.NoAnswer {
            #expect(noAnswer.dispatched)
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }
}
