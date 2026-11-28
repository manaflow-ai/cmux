@testable import CmuxNextCloud
import Foundation
import Testing

/// The Slack page's calls are the daemon's `owner.slack` and `owner.slack_awake` (cmux-cloud-api `slack.rs`): the app
/// sends the route or the Chief, the credential and the team, and passes back the body the daemon answers.
@Suite(.serialized)
struct CloudSlackTests {
    typealias FakeDaemon = CloudDaemonRunTests.FakeDaemon

    private func client(_ daemon: FakeDaemon) throws -> CloudDaemon {
        var client = CloudDaemon.workerMachines(baseURL: try #require(URL(string: "https://platform.standin.invalid")),
                                                accessToken: { "person-access" }, teamID: { "team-selected" })
        client.daemonCall = { input, _ in try daemon.run(input) }
        return client
    }

    @Test func slackRequestsUseTheSelectedTeamAndWorkerAuth() async throws {
        let daemon = FakeDaemon { _, _, _ in #"{"ok":true,"body":{"connected":false,"teams":[]}}"# }
        let client = try client(daemon)
        let data = try await client.slackRequest(method: "GET")
        let answer = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(answer["connected"] as? Bool == false)
        _ = try await client.slackRequest(method: "POST")
        _ = try await client.slackRequest(method: "DELETE")
        let requests = daemon.requests
        #expect(requests.map { $0["call"] as? String } == ["owner.slack", "owner.slack", "owner.slack"])
        #expect(requests.map { ($0["args"] as? [String: Any])?["route"] as? String } == ["connection", "install_link", "disconnect"])
        let request = try #require(requests.first)
        #expect(request["api"] as? String == "https://platform.standin.invalid")
        #expect(request["auth"] as? String == "worker")
        #expect(request["credential"] as? String == "person-access")
        #expect(request["team"] as? String == "team-selected")
    }

    @Test func anUnknownMethodSendsNothing() async throws {
        let daemon = FakeDaemon { _, _, _ in #"{"ok":true,"body":{}}"# }
        await #expect(throws: CloudAPIError.self) { _ = try await client(daemon).slackRequest(method: "PATCH") }
        #expect(daemon.requests.isEmpty)
    }

    @Test func ownBotPostsToTheAppsRouteWithWorkerAuth() async throws {
        let daemon = FakeDaemon { _, _, _ in #"{"ok":true,"body":{"installUrl":"https://slack.invalid/install"}}"# }
        _ = try await client(daemon).slackRequest(method: "POST", ownBot: ("xoxe.xoxp-1-AAAAAAAAAAAA", "Acme"))
        let request = try #require(daemon.requests.first)
        #expect(request["call"] as? String == "owner.slack")
        #expect(request["auth"] as? String == "worker")
        let args = try #require(request["args"] as? [String: Any])
        #expect(args["route"] as? String == "create_app")
        #expect(args["configToken"] as? String == "xoxe.xoxp-1-AAAAAAAAAAAA")
        #expect(args["name"] as? String == "Acme")
    }

    @Test func slackAwakeReadsAndWritesTheChiefsAllowance() async throws {
        let chief = "agent_01HZX9ABCDEFGHJKMNPQRSTVWX"
        let daemon = FakeDaemon { _, _, _ in #"{"ok":true,"body":{"allowance_seconds":7200}}"# }
        let client = try client(daemon)
        let data = try await client.slackAwake(chief: chief)
        let value = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(value["allowance_seconds"] as? Int == 7200)
        _ = try await client.slackAwake(chief: chief, allowance: .some(3600))
        _ = try await client.slackAwake(chief: chief, allowance: .some(nil))
        let args = daemon.args("owner.slack_awake")
        #expect(args.count == 3)
        #expect(args[0]["chief"] as? String == chief)
        #expect(args[0]["allowance"] == nil, "a read sends no allowance")
        #expect(args[1]["allowance"] as? Int == 3600)
        #expect(args[2]["allowance"] is NSNull, "null: back to the default")
        #expect(daemon.requests.allSatisfy { $0["auth"] as? String == "owner" })
    }

    @Test func aBadChiefIDNeverLeavesTheApp() async throws {
        let daemon = FakeDaemon { _, _, _ in #"{"ok":true,"body":{}}"# }
        for id in ["agent_01HZX9ABCDEFGHJKMNPQRSTVWI", "agent_short", "../v1/admin", ""] {
            await #expect(throws: CloudAPIError.self) { _ = try await client(daemon).slackAwake(chief: id) }
        }
        #expect(daemon.requests.isEmpty)
    }

    @Test func aRefusalComesBackAsItsCode() async throws {
        let daemon = FakeDaemon { _, _, _ in #"{"ok":false,"error":{"kind":"http","status":403,"code":"forbidden"}}"# }
        do {
            _ = try await client(daemon).slackRequest(method: "GET")
            Issue.record("expected a refusal")
        } catch let error as CloudAPIError {
            guard case .http(let status, let code, _, _, _) = error else { Issue.record("not an HTTP refusal: \(error)"); return }
            #expect(status == 403)
            #expect(code == "forbidden")
        }
    }
}
