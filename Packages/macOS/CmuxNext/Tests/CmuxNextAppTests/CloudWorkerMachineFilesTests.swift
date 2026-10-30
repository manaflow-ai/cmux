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
                                  cmuxTeam: request.value(forHTTPHeaderField: "x-cmux-team")))
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

    /// The Codex broker on a Worker machine asks its link's owner answer, never `/api/vm`'s attach
    /// answer or record (a Worker machine has no row there).
    @Test func theCodexBrokerOnAWorkerMachineNeverAsksTheClassicRoutes() async throws {
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa", scope = CloudCodexBrokerScope(userID: "u1", teamID: "team-1")
        WorkerAPI.seen = []
        let refused = CloudCodexBrokerTarget(api: worker(), machineID: machine, scope: scope,
                                             callerOwnsVM: { false }, isLive: { true })
        #expect(try await refused.capability().ownerVM == false)
        #expect(try await refused.isLive())
        #expect(WorkerAPI.seen.isEmpty)

        let owned = CloudCodexBrokerTarget(api: worker(), machineID: machine, scope: scope,
                                           callerOwnsVM: { true }, isLive: { true })
        #expect(try await owned.capability().ownerVM)
        #expect(WorkerAPI.seen.map(\.url) == ["https://machines.standin.invalid/v1/cloud/machines/\(machine)/exec"])
    }
}
