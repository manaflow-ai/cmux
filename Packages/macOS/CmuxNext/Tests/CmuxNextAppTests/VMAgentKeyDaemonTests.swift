@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextControl
import Foundation
import Testing

/// `vm.agent_key.create`'s mint goes over cmux-cloud-api's `vm.agent_key_create` (no URLRequest in the app):
/// the owner credential and team, the planned body as JSON text, and the VM API's status and body back for
/// Rust's answer reading; no answer at all is status 0 (unreachable).
@Suite(.serialized)
struct VMAgentKeyDaemonTests {
    typealias FakeDaemon = CloudDaemonRunTests.FakeDaemon

    private func issuer() throws -> AppControl.VMIssuer {
        AppControl.VMIssuer(backend: .production, vmOrigin: nil, teamID: "team-1", accessToken: "access", machineIO: nil)
    }

    @Test func theMintSendsTheBodyAsOwnerAndAnswersTheStatusAndBody() async throws {
        let daemon = FakeDaemon { _, _, _ in #"{"ok":true,"body":{"status":201,"body":"{\"key\":\"cmux_ak_x\"}"}}"# }
        let base = try #require(URL(string: "https://vm.invalid"))
        let answer = await AppControl.vmAgentKeyMint(try issuer(), baseURL: base, body: .object(["name": "cli", "maxVms": 2]),
                                                     run: { input, _ in try daemon.run(input) })
        #expect(answer.status == 201)
        #expect(String(decoding: answer.body, as: UTF8.self) == #"{"key":"cmux_ak_x"}"#)
        let request = try #require(daemon.requests.first)
        #expect(request["call"] as? String == "vm.agent_key_create")
        #expect(request["auth"] as? String == "owner")
        #expect(request["api"] as? String == "https://vm.invalid")
        #expect(request["credential"] as? String == "access")
        #expect(request["team"] as? String == "team-1")
        let text = try #require(daemon.args("vm.agent_key_create").first?["body_json"] as? String)
        let body = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(body["name"] as? String == "cli")
        #expect(body["maxVms"] as? Int == 2)
    }

    @Test func noAnswerIsStatusZero() async throws {
        let base = try #require(URL(string: "https://vm.invalid"))
        let refused = FakeDaemon { _, _, _ in #"{"ok":false,"error":{"kind":"transport","message":"down"}}"# }
        let failed = await AppControl.vmAgentKeyMint(try issuer(), baseURL: base, body: .object([:]), run: { input, _ in try refused.run(input) })
        #expect(failed.status == 0)
        // No bundled cmux: nothing runs, status 0.
        let none = await AppControl.vmAgentKeyMint(try issuer(), baseURL: base, body: .object([:]))
        #expect(none.status == 0)
    }
}
