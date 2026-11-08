@testable import CmuxNextApp
@testable import CmuxNextCloud
import Foundation
import Testing

/// cmux-platform#89, part 2: a Worker machine (the Cloud app server link) has no `/api/vm` row, so
/// `cmux cloud deliver-secrets`, `apply-machine-config` and credential recovery failed at their
/// first read ("This machine has no finished machine config yet"). Its exec and file routes are the
/// same requests under `/v1/cloud/machines/{id}/` on the cmux API Worker, with the person's Stack
/// session and the team in `x-cmux-team`: a Mac install has no execute grant (backend
/// domains/user.ts), so the route's caller check (cloud-client-session.ts) refuses its token with a 403.
@Suite(.serialized)
struct CloudWorkerMachineFilesTests {
    nonisolated final class WorkerAPI: URLProtocol {
        struct Seen {
            var method: String
            var url: String
            var authorization: String?
            var refresh: String?
            var team: String?
            var cmuxTeam: String?
            var body: [String: Any] = [:]
        }

        nonisolated(unsafe) static var seen: [Seen] = []

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            Self.seen.append(Seen(method: request.httpMethod ?? "", url: url.absoluteString,
                                  authorization: request.value(forHTTPHeaderField: "Authorization"),
                                  refresh: request.value(forHTTPHeaderField: "X-Stack-Refresh-Token"),
                                  team: request.value(forHTTPHeaderField: "X-Cmux-Team-Id"),
                                  cmuxTeam: request.value(forHTTPHeaderField: "x-cmux-team"),
                                  body: Self.body(of: request)))
            let body = switch url.path {
            case let path where path.hasSuffix("/exec"): #"{"exitCode":0,"stdout":"ok","stderr":""}"#
            case let path where path.hasSuffix("/fs/read"): #"{"path":"/a","dataBase64":"aGk=","size":2}"#
            default: #"{"ok":true,"path":"/a"}"#
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// The JSON body (URLProtocol sees it as a stream).
        static func body(of request: URLRequest) -> [String: Any] {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    guard read > 0 else { break }
                    data.append(buffer, count: read)
                }
                stream.close()
            }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
    }

    private static let origin = URL(string: "https://machines.standin.invalid") ?? URL(fileURLWithPath: "/dev/null")

    private func worker() -> CloudAPIClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [WorkerAPI.self]
        return CloudAPIClient.workerMachines(baseURL: Self.origin, accessToken: { "session-access" }, teamID: { "team_cmux" },
                                             session: URLSession(configuration: sessionConfiguration))
    }

    @Test func execAndFilesGoToTheWorkerRoutesWithThePersonsSessionAndCmuxTeam() async throws {
        WorkerAPI.seen = []
        // A flow that pins the app's (Stack) team keeps the cmux team the Worker knows.
        let api = worker().pinningTeam("stack-team-1")
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa"
        #expect(try await api.exec(machine, command: "true", timeoutMs: 8_000).stdout == "ok")
        #expect(try await api.readFile(machine, path: "/home/cmux/.cmux/machine-config/status.json").dataBase64 == "aGk=")
        try await api.writeFile(machine, path: "/a", data: Data("hi".utf8), mode: 0o644)
        #expect(WorkerAPI.seen.map(\.method) == ["POST", "GET", "POST"])
        #expect(WorkerAPI.seen.map(\.url) == [
            "https://machines.standin.invalid/v1/cloud/machines/\(machine)/exec",
            "https://machines.standin.invalid/v1/cloud/machines/\(machine)/fs/read?path=/home/cmux/.cmux/machine-config/status.json",
            "https://machines.standin.invalid/v1/cloud/machines/\(machine)/fs/write",
        ])
        for request in WorkerAPI.seen {
            // A Mac install token here is a 403 for every Mac user: its grant has no execute.
            #expect(request.authorization == "Bearer session-access")
            #expect(request.cmuxTeam == "team_cmux")
            #expect(request.refresh == nil, "the Stack refresh token never goes to the Worker")
            #expect(request.team == nil)
        }
    }

    /// Set Up GitHub's script runs on the Worker exec route, as `cmux`: a NEXT machine id is a Worker
    /// id, which classic `/api/vm/{id}/exec` does not know.
    @Test func gitHubSetupExecsOnTheWorkerRoute() async throws {
        WorkerAPI.seen = []
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa", identity = CloudGitHubSetup.GitIdentity(name: "Ann", email: "ann@example.test")
        let outcome = try await CloudGitHubSetup.run(identity, app: true, machine: machine, on: worker())
        #expect(outcome == CloudGitHubSetup.parse(exitCode: 0, stdout: "ok"))
        #expect(WorkerAPI.seen.map(\.url) == ["https://machines.standin.invalid/v1/cloud/machines/\(machine)/exec"])
        #expect(WorkerAPI.seen.first?.body["command"] as? String == CloudGitHubSetup.command(identity, app: true))
        #expect(WorkerAPI.seen.first?.body["timeoutMs"] as? Int == CloudGitHubSetup.timeoutMs)
    }

    @Test func theClassicClientKeepsItsRoutesAndHeaders() async throws {
        WorkerAPI.seen = []
        let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
                                                       process: [:], isDebugBuild: true)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [WorkerAPI.self]
        let api = CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { "team-1" },
                                 session: URLSession(configuration: sessionConfiguration))
        _ = try await api.exec("m1", command: "true")
        #expect(WorkerAPI.seen.map(\.url) == ["https://vm-api.standin.invalid/api/vm/m1/exec"])
        #expect(WorkerAPI.seen.first?.authorization == "Bearer access")
        #expect(WorkerAPI.seen.first?.refresh == "refresh")
        #expect(WorkerAPI.seen.first?.team == "team-1")
    }

    @Test func aWorkerRefusalNamesItsNestedCodeAndMessage() {
        let body = Data(#"{"ok":false,"error":{"code":"vm_not_running","message":"Start the machine first."}}"#.utf8)
        #expect(CloudAPIError.from(status: 409, data: body, headerCode: nil)
            == .http(status: 409, code: "vm_not_running", message: "Start the machine first.", action: nil, traceId: nil))
        #expect(CloudAPIError.from(status: 409, data: body, headerCode: "vm_not_running")
            == .http(status: 409, code: "vm_not_running", message: "Start the machine first.", action: nil, traceId: nil))
    }
}
