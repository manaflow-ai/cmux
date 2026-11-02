@testable import CmuxNextCloud
@testable import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing

/// A Worker machine's exec and file routes forward to the bundled cmux-tui (`cmux cloud
/// machine-io`), which reaches the provider directly with a client session. Swift only forwards:
/// the request goes on the child's stdin (never argv), the answer line is decoded as the route's own
/// answer, and a child that gives no answer sends the request to the cmux API route instead.
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

    /// A stand-in `cmux` that saves its stdin and argv, then prints `line`. It answers the empty
    /// `machine-io` probe as a current cmux does, unless `speaksMachineIO` is false (an older cmux),
    /// and adds a line to `probes` for each probe.
    private func fakeCLI(printing line: String, speaksMachineIO: Bool = true) throws -> (binary: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("machine-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("cmux")
        let probe = speaksMachineIO ? #"{"route":"none","status":400,"code":"validation.invalid","body":null}"# : line
        let script = "#!/bin/sh\ninput=$(cat)\nif [ \"$input\" = '{}' ]; then echo probe >> \"\(folder.path)/probes\"; printf '%s\\n' '\(probe)'; exit 2; fi\nprintf '%s' \"$input\" > \"\(folder.path)/stdin\"\necho \"$@\" > \"\(folder.path)/argv\"\nprintf '%s\\n' '\(line)'\n"
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

    @Test func aWriteGoesOnStdinAndTheAnswerDecodesAsTheRoutes() async throws {
        let (binary, folder) = try fakeCLI(printing: #"{"route":"direct","status":200,"code":null,"body":{"path":"/a","dataBase64":"aGk=","size":2}}"#)
        defer { try? FileManager.default.removeItem(at: folder) }
        Route.paths = []
        let api = client(binary, folder)
        let big = Data(repeating: 7, count: 1_000_000)
        try await api.writeFile("vm_abcdefghij0123456789", path: "/a", data: big, mode: 0o640)
        let request = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("stdin"))) as? [String: Any])
        #expect(request["op"] as? String == "write")
        #expect(request["machine"] as? String == "vm_abcdefghij0123456789")
        #expect(request["credential"] as? String == "session-access")
        #expect(request["team"] as? String == "team_cmux")
        #expect(request["mode"] as? Int == 0o640)
        #expect(request["data_base64"] as? String == big.base64EncodedString())
        #expect(request["cache_dir"] as? String == folder.appendingPathComponent("sessions").path)
        let argv = try String(contentsOf: folder.appendingPathComponent("argv"), encoding: .utf8)
        #expect(argv == "cloud machine-io\n", "the credential is never in argv")
        let read = try await api.readFile("vm_abcdefghij0123456789", path: "/a")
        #expect(read.dataBase64 == "aGk=")
        #expect(Route.paths.isEmpty)
    }

    @Test func aRefusalThrowsWhatTheRouteWouldHave() async throws {
        let line = #"{"route":"proxy","status":404,"code":"vm_file_not_found","body":{"ok":false,"error":{"code":"vm_file_not_found","message":"no such file: /a"}}}"#
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

    @Test func noAnswerOrAnUnusableRequestTakesTheRoute() async throws {
        for line in ["not json", #"{"route":"none","status":400,"code":"validation.invalid","body":null}"#] {
            let (binary, folder) = try fakeCLI(printing: line)
            defer { try? FileManager.default.removeItem(at: folder) }
            Route.paths = []
            let stat = try await client(binary, folder).statFile("vm_abcdefghij0123456789", path: "/a")
            #expect(stat.kind == "file")
            #expect(Route.paths == ["/v1/cloud/machines/vm_abcdefghij0123456789/fs/stat"])
        }
    }

    @Test func aChangeThatMayHaveRunIsNeverSentAgain() async throws {
        let (binary, folder) = try fakeCLI(printing: "not json")
        defer { try? FileManager.default.removeItem(at: folder) }
        Route.paths = []
        do {
            try await client(binary, folder).makeDirectory("vm_abcdefghij0123456789", path: "/a")
            Issue.record("expected the unanswered change to be reported")
        } catch CloudAPIError.transport {}
        #expect(Route.paths.isEmpty, "a change cmux may have made is not replayed over HTTP")

        let (refusing, other) = try fakeCLI(printing: #"{"route":"none","status":400,"code":"validation.invalid","body":null}"#)
        defer { try? FileManager.default.removeItem(at: other) }
        try await client(refusing, other).makeDirectory("vm_abcdefghij0123456789", path: "/a")
        #expect(Route.paths == ["/v1/cloud/machines/vm_abcdefghij0123456789/fs/mkdir"], "a change cmux never took goes over HTTP")
    }

    @Test func aCmuxWithoutMachineIOSendsEveryCallOverHTTP() async throws {
        let (binary, folder) = try fakeCLI(printing: "error: unrecognized subcommand machine-io", speaksMachineIO: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        Route.paths = []
        try await client(binary, folder).makeDirectory("vm_abcdefghij0123456789", path: "/a")
        #expect(Route.paths == ["/v1/cloud/machines/vm_abcdefghij0123456789/fs/mkdir"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("stdin").path), "the call itself never ran")
    }

    /// The probe answers belong to the machine IO the app makes (and the copies its client holds), not
    /// to the process: a copy uses what its instance learned, another instance asks the binary again.
    @Test func theProbeCacheIsTheInstancesOwn() async throws {
        let (binary, folder) = try fakeCLI(printing: "unused")
        defer { try? FileManager.default.removeItem(at: folder) }
        let probes = folder.appendingPathComponent("probes")
        func asked() -> Int { ((try? String(contentsOf: probes, encoding: .utf8)) ?? "").split(separator: "\n").count }
        let first = CloudMachineIO(binary: binary, cacheDirectory: folder, probes: CloudMachineIO.Probes(), work: BackgroundWork())
        #expect(try await first.speaksMachineIO())
        #expect(try await first.speaksMachineIO())
        let copy = first
        #expect(try await copy.speaksMachineIO())
        #expect(asked() == 1, "one probe for the instance and its copies")
        let second = CloudMachineIO(binary: binary, cacheDirectory: folder, probes: CloudMachineIO.Probes(), work: BackgroundWork())
        #expect(try await second.speaksMachineIO())
        #expect(asked() == 2, "another instance asks the binary itself")
    }

    #if DEBUG
    /// The app calls the machine routes from main-actor handlers: the probe's stat, the temp file and the
    /// answer's read and parse run off the main thread, so the blocking detector records nothing there.
    @MainActor @Test func aMainActorCallerNeverBlocksTheMainThread() async throws {
        let (binary, folder) = try fakeCLI(printing: #"{"route":"direct","status":200,"code":null,"body":{"path":"/a","dataBase64":"aGk=","size":2}}"#)
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
    /// the bundled cmux is there is asked by the first call, off the main thread.
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

    /// A build without a bundled cmux sends every call over HTTP, as it did when the app made no machine IO for it.
    @Test func aBuildWithoutTheBundledCmuxSendsEveryCallOverHTTP() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("machine-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        Route.paths = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Route.self]
        let api = CloudAPIClient.workerMachines(baseURL: URL(string: "https://machines.standin.invalid") ?? folder,
                                                accessToken: { "session-access" }, teamID: { "team_cmux" },
                                                session: URLSession(configuration: configuration),
                                                machineIO: CloudMachineIO(bundleResources: folder, cloudRoot: folder, work: BackgroundWork()))
        try await api.makeDirectory("vm_abcdefghij0123456789", path: "/a")
        #expect(Route.paths == ["/v1/cloud/machines/vm_abcdefghij0123456789/fs/mkdir"])
    }

    /// Every file call of a machine IO call runs on the app's blocking-work lanes (`BackgroundWork` `.files`),
    /// never on the cooperative pool. With the lanes shut down (quit refuses new items), the probe's stat and a
    /// run's temp file are refused, so no file is touched and the child never starts.
    @Test func theFileCallsRunOnTheAppsFileLane() async throws {
        let (binary, folder) = try fakeCLI(printing: #"{"route":"direct","status":200,"code":null,"body":{}}"#)
        defer { try? FileManager.default.removeItem(at: folder) }
        let closed = BackgroundWork()
        await closed.shutdown()
        let machineIO = CloudMachineIO(binary: binary, cacheDirectory: folder, probes: CloudMachineIO.Probes(), work: closed)
        await #expect(throws: CancellationError.self, "the probe's stat") { try await machineIO.speaksMachineIO() }
        await #expect(throws: CancellationError.self, "the answer's temp file") {
            try await CloudMachineIO.run(binary, arguments: ["cloud", "machine-io"], stdin: Data(#"{"op":"stat"}"#.utf8),
                                         timeout: .seconds(10), work: closed)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("stdin").path), "the child never started")
    }
}
