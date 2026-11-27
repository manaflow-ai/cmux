@testable import CmuxNextCloud
@testable import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// A Worker machine's exec and file routes are the daemon's `machine.io` through the bundled cmux-tui
/// (`cmux cloud api`), which reaches the provider directly with a client session and falls back to the
/// cmux API's routes on its own. Swift only forwards: the request goes on the child's stdin (never argv),
/// the answer is decoded as the route's own answer, and there is no Swift HTTP fallback: a child that gives
/// no answer, or no bundled cmux, is an error, never a request to the route.
@Suite(.serialized)
struct CloudMachineIOTests {
    nonisolated final class Route: URLProtocol {
        nonisolated(unsafe) static var paths: [String] = []
        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])
            else { return }
            Self.paths.append(url.path)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"path":"/a","kind":"file","size":1}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    /// A stand-in `cmux` that saves its stdin and argv, then prints `line`.
    private func fakeCLI(printing line: String) throws -> (binary: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("machine-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("cmux")
        let script = "#!/bin/sh\ninput=$(cat)\nprintf '%s' \"$input\" > \"\(folder.path)/stdin\"\necho \"$@\" > \"\(folder.path)/argv\"\nprintf '%s\\n' '\(line)'\n"
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return (binary, folder)
    }

    private func client(_ binary: URL, _ folder: URL) -> CloudAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Route.self]
        return CloudAPIClient.workerMachines(baseURL: URL(string: "https://machines.standin.invalid") ?? folder,
                                             accessToken: { "session-access" }, teamID: { "team_cmux" },
                                             session: URLSession(configuration: configuration),
                                             machineIO: CloudMachineIO(binary: binary, cacheDirectory: folder.appendingPathComponent("sessions"), work: BackgroundWork()))
    }

    private static let file = #"{"ok":true,"body":{"path":"/a","dataBase64":"aGk=","size":2}}"#

    @Test func aWriteGoesOnStdinAndTheAnswerDecodesAsTheRoutes() async throws {
        let (binary, folder) = try fakeCLI(printing: Self.file)
        defer { try? FileManager.default.removeItem(at: folder) }
        Route.paths = []
        let api = client(binary, folder)
        let big = Data(repeating: 7, count: 1_000_000)
        try await api.writeFile("vm_abcdefghij0123456789", path: "/a", data: big, mode: 0o640)
        let request = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("stdin"))) as? [String: Any])
        #expect(request["call"] as? String == "machine.io")
        #expect(request["auth"] as? String == "owner")
        #expect(request["credential"] as? String == "session-access")
        #expect(request["team"] as? String == "team_cmux")
        let args = try #require(request["args"] as? [String: Any])
        #expect(args["op"] as? String == "write")
        #expect(args["machine"] as? String == "vm_abcdefghij0123456789")
        #expect(args["path"] as? String == "/a")
        #expect(args["mode"] as? Int == 0o640)
        #expect(args["data_base64"] as? String == big.base64EncodedString())
        let argv = try String(contentsOf: folder.appendingPathComponent("argv"), encoding: .utf8)
        #expect(argv == "cloud api\n", "the credential is never in argv")
        let read = try await api.readFile("vm_abcdefghij0123456789", path: "/a")
        #expect(read.dataBase64 == "aGk=")
        #expect(Route.paths.isEmpty)
    }

    @Test func anExecSendsItsTimeoutAsTheDaemonReadsIt() async throws {
        let seen = Mutex<(input: Data, timeout: Duration)?>(nil)
        var api = CloudAPIClient.workerMachines(baseURL: URL(string: "https://machines.standin.invalid") ?? URL(fileURLWithPath: "/"),
                                                accessToken: { "session-access" }, teamID: { "team_cmux" })
        api.daemon.daemonCall = { input, timeout in
            seen.withLock { $0 = (input, timeout) }
            return Data(#"{"ok":true,"body":{"exitCode":0,"stdout":"hi","stderr":""}}"#.utf8)
        }
        let result = try await api.exec("vm_abcdefghij0123456789", command: "echo hi", timeoutMs: 40_000)
        #expect(result.stdout == "hi")
        let (input, timeout) = try #require(seen.withLock { $0 })
        let request = try #require(try JSONSerialization.jsonObject(with: input) as? [String: Any])
        let args = try #require(request["args"] as? [String: Any])
        #expect(args["op"] as? String == "exec")
        #expect(args["command"] as? String == "echo hi")
        #expect(args["timeout_ms"] as? Int == 40_000)
        #expect(args["timeoutMs"] == nil)
        #expect(timeout == .seconds(75), "the route's 40 s and 5 s, then 30 s for a child that hangs")
    }

    @Test func aRefusalThrowsWhatTheRouteWouldHave() async throws {
        let line = #"{"ok":false,"error":{"kind":"http","status":404,"code":"vm_file_not_found","message":"no such file: /a"}}"#
        let (binary, folder) = try fakeCLI(printing: line)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            _ = try await client(binary, folder).statFile("vm_abcdefghij0123456789", path: "/a")
            Issue.record("expected a refusal")
        } catch let CloudAPIError.http(status, code, message, _, _) {
            #expect(status == 404)
            #expect(code == "vm_file_not_found")
            #expect(message == "no such file: /a")
        }
    }

    @Test func noAnswerIsAnErrorNeverTheHTTPRoute() async throws {
        let (binary, folder) = try fakeCLI(printing: "not json")
        defer { try? FileManager.default.removeItem(at: folder) }
        Route.paths = []
        await #expect(throws: CloudAPIError.transport("cmux did not answer cloud.machine.io")) {
            _ = try await client(binary, folder).statFile("vm_abcdefghij0123456789", path: "/a")
        }
        await #expect(throws: CloudAPIError.transport("cmux did not answer cloud.machine.io")) {
            try await client(binary, folder).makeDirectory("vm_abcdefghij0123456789", path: "/a")
        }
        #expect(Route.paths.isEmpty, "nothing goes over Swift HTTP")
    }

    @Test func aChangeThatMayHaveRunIsReportedSo() async throws {
        var api = CloudAPIClient.workerMachines(baseURL: URL(string: "https://machines.standin.invalid") ?? URL(fileURLWithPath: "/"),
                                                accessToken: { "session-access" }, teamID: { "team_cmux" })
        api.daemon.daemonCall = { _, _ in throw CloudMachineIO.NoAnswer(dispatched: true) }
        await #expect(throws: CloudAPIError.transport("cmux did not answer; the mkdir may have run")) {
            try await api.makeDirectory("vm_abcdefghij0123456789", path: "/a")
        }
        api.daemon.daemonCall = { _, _ in throw CloudMachineIO.NoAnswer(dispatched: false) }
        await #expect(throws: CloudAPIError.transport("cmux is not available")) {
            try await api.makeDirectory("vm_abcdefghij0123456789", path: "/a")
        }
    }

    #if DEBUG
    /// The app calls the machine routes from main-actor handlers: the temp file and the
    /// answer's read and parse run off the main thread, so the blocking detector records nothing there.
    @MainActor @Test func aMainActorCallerNeverBlocksTheMainThread() async throws {
        let (binary, folder) = try fakeCLI(printing: Self.file)
        defer { try? FileManager.default.removeItem(at: folder) }
        let api = client(binary, folder)
        let table = BlockingViolationTable(mode: .record)
        let read = try await BlockingViolationTable.$scoped.withValue(table) {
            try await api.readFile("vm_abcdefghij0123456789", path: "/a")
        }
        await table.flush()
        #expect(read.dataBase64 == "aGk=")
        #expect(BlockingDetector(table: table).sites.isEmpty)
    }
    #endif

    #if DEBUG
    /// The Cloud service makes its machine IO on the main thread at start: that makes no file system call. Whether
    /// the bundled cmux is there is found by the first call, off the main thread.
    @MainActor @Test func makingTheAppsMachineIOTouchesNoFileOnTheMainThread() async throws {
        let (binary, folder) = try fakeCLI(printing: "unused")
        defer { try? FileManager.default.removeItem(at: folder) }
        let resources = folder.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binary, to: resources.appendingPathComponent("bin/cmux"))
        let table = BlockingViolationTable(mode: .record)
        let machineIO = BlockingViolationTable.$scoped.withValue(table) {
            CloudMachineIO(bundleResources: resources, cloudRoot: folder, work: BackgroundWork())
        }
        await table.flush()
        #expect(BlockingDetector(table: table).sites.isEmpty)
        #expect(machineIO?.binary.path == resources.appendingPathComponent("bin/cmux").path)
    }
    #endif

    /// A build without a bundled cmux sends nothing over HTTP: its calls are `transport("cmux is not available")`,
    /// as every daemon call is.
    @Test func aBuildWithoutTheBundledCmuxSendsNothing() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("machine-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        Route.paths = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Route.self]
        for machineIO in [CloudMachineIO(bundleResources: folder, cloudRoot: folder, work: BackgroundWork()), nil] {
            let api = CloudAPIClient.workerMachines(baseURL: URL(string: "https://machines.standin.invalid") ?? folder,
                                                    accessToken: { "session-access" }, teamID: { "team_cmux" },
                                                    session: URLSession(configuration: configuration), machineIO: machineIO)
            await #expect(throws: CloudAPIError.transport("cmux is not available")) {
                try await api.makeDirectory("vm_abcdefghij0123456789", path: "/a")
            }
        }
        #expect(Route.paths.isEmpty)
    }

    /// Every file call of a machine IO call runs on the app's blocking-work lanes (`BackgroundWork` `.files`),
    /// never on the cooperative pool. With the lanes shut down (quit refuses new items), a run's temp file is
    /// refused, so no file is touched and the child never starts.
    @Test func theFileCallsRunOnTheAppsFileLane() async throws {
        let (binary, folder) = try fakeCLI(printing: #"{"ok":true,"body":{}}"#)
        defer { try? FileManager.default.removeItem(at: folder) }
        let closed = BackgroundWork()
        await closed.shutdown()
        await #expect(throws: CancellationError.self, "the answer's temp file") {
            try await CloudMachineIO.run(binary, arguments: ["cloud", "api"], stdin: Data(#"{"call":"machine.io"}"#.utf8),
                                         timeout: .seconds(10), work: closed)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("stdin").path), "the child never started")
    }
}
