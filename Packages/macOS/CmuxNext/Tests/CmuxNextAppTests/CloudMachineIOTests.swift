@testable import CmuxNextCloud
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

    /// A stand-in `cmux` that saves its stdin and argv, then prints `line`.
    private func fakeCLI(printing line: String) throws -> (binary: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("machine-io-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let binary = folder.appendingPathComponent("cmux")
        let script = "#!/bin/sh\ncat > \"\(folder.path)/stdin\"\necho \"$@\" > \"\(folder.path)/argv\"\nprintf '%s\\n' '\(line)'\n"
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
                                             machineIO: CloudMachineIO(binary: binary, cacheDirectory: folder.appendingPathComponent("sessions")))
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
}
