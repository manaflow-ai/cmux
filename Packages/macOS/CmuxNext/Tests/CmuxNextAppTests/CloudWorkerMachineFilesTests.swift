@testable import CmuxNextApp
@testable import CmuxNextCloud
import Foundation
import Testing

/// cmux-platform#89, part 2: a Worker machine (the Cloud app server link) has no `/api/vm` row, so
/// `cmux cloud deliver-secrets`, `apply-machine-config` and credential recovery failed at their
/// first read ("This machine has no finished machine config yet"). Its exec and file routes are the
/// same requests under `/v1/vm/{id}/` on the Worker machines origin, with the install token as the
/// only credential.
@Suite(.serialized)
struct CloudWorkerMachineFilesTests {
    nonisolated final class WorkerAPI: URLProtocol {
        struct Seen {
            var method: String
            var url: String
            var authorization: String?
            var refresh: String?
            var team: String?
        }

        nonisolated(unsafe) static var seen: [Seen] = []

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            Self.seen.append(Seen(method: request.httpMethod ?? "", url: url.absoluteString,
                                  authorization: request.value(forHTTPHeaderField: "Authorization"),
                                  refresh: request.value(forHTTPHeaderField: "X-Stack-Refresh-Token"),
                                  team: request.value(forHTTPHeaderField: "X-Cmux-Team-Id")))
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
        return CloudAPIClient.workerMachines(baseURL: Self.origin, installToken: { "install-token" },
                                             session: URLSession(configuration: sessionConfiguration))
    }

    @Test func execAndFilesGoToTheWorkerRoutesWithOnlyTheInstallToken() async throws {
        WorkerAPI.seen = []
        let api = worker().pinningTeam("team_1")
        let machine = "vm_aaaaaaaaaaaaaaaaaaaa"
        #expect(try await api.exec(machine, command: "true", timeoutMs: 8_000).stdout == "ok")
        #expect(try await api.readFile(machine, path: "/home/cmux/.cmux/machine-config/status.json").dataBase64 == "aGk=")
        try await api.writeFile(machine, path: "/a", data: Data("hi".utf8), mode: 0o644)
        #expect(WorkerAPI.seen.map(\.method) == ["POST", "GET", "POST"])
        #expect(WorkerAPI.seen.map(\.url) == [
            "https://machines.standin.invalid/v1/vm/\(machine)/exec",
            "https://machines.standin.invalid/v1/vm/\(machine)/fs/read?path=/home/cmux/.cmux/machine-config/status.json",
            "https://machines.standin.invalid/v1/vm/\(machine)/fs/write",
        ])
        for request in WorkerAPI.seen {
            #expect(request.authorization == "Bearer install-token")
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

    @Test func theWorkerMachinesOriginFollowsTheAuthEnvironment() {
        let production = CloudConfiguration.resolve(bundleID: nil, bundled: [:], process: [:], isDebugBuild: false)
        #expect(production.machineRoutesBaseURL().absoluteString == "https://cmux-platform-production.debussy.workers.dev")
        let staging = CloudConfiguration.resolve(bundleID: nil, bundled: [:], process: [:], isDebugBuild: true)
        #expect(staging.machineRoutesBaseURL().absoluteString == "https://cmux-platform-staging.debussy.workers.dev")
        let override = ["CMUX_NEXT_MACHINE_API_URL": "https://cmux-platform-development.debussy.workers.dev"]
        #expect(staging.machineRoutesBaseURL(environment: override).absoluteString == "https://cmux-platform-development.debussy.workers.dev")
        #expect(production.machineRoutesBaseURL(environment: override).absoluteString == "https://cmux-platform-production.debussy.workers.dev",
                "a Release build never sends a credential to another origin")
    }
}
