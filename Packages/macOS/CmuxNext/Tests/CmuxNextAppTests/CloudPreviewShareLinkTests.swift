import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextCloudUI
import Foundation
import Testing

/// A preview's anonymous share link is the daemon's `cloud.previews.create_link` and `cloud.previews.revoke_link`
/// (cmux-cloud-api `previews.rs`): the app sends the machine, port and link id, the platform origin and the
/// person's access and team, and decodes the platform's answer the daemon passes back.
@Suite(.serialized)
struct CloudPreviewShareLinkTests {
    typealias FakeDaemon = CloudDaemonRunTests.FakeDaemon

    nonisolated static let created = #"{"ok":true,"body":{"link":{"linkId":"link_123","creator":"user_1","team":"team_1","machine":"vm_abc","port":3000,"hostname":"preview.example","ruleId":"rule_1","createdAt":1700000000000,"expiresAt":1700086400000,"maxUses":null,"redemptions":0,"revokedAt":null},"url":"https://preview.example/?cmux_share=secret"}}"#

    private func daemon() -> FakeDaemon {
        FakeDaemon { call, _, _ in call == "previews.create_link" ? Self.created : #"{"ok":true,"body":{"revoked":true}}"# }
    }

    private func api(_ daemon: FakeDaemon) throws -> CloudDaemon {
        var worker = CloudDaemon.workerMachines(baseURL: try #require(URL(string: "https://worker.invalid")),
                                                   accessToken: { "access" }, teamID: { "team_1" })
        worker.daemonCall = { input, _ in try daemon.run(input) }
        return worker.previewClient(baseURL: try #require(URL(string: "https://platform.invalid")))
    }

    @Test func createCopiesThePlatformLinkAndRevokeTargetsItsID() async throws {
        let daemon = daemon()
        let api = try api(daemon)

        let created = try await api.createPreviewShareLink("vm_abc", port: 3000)
        #expect(created.link.linkId == "link_123")
        #expect(created.url == "https://preview.example/?cmux_share=secret")
        #expect(created.link.maxUses == nil)
        let revoked = try await api.revokePreviewShareLink("vm_abc", port: 3000, linkID: created.link.linkId)
        #expect(revoked.revoked)

        let requests = daemon.requests
        #expect(requests.map { $0["call"] as? String } == ["previews.create_link", "previews.revoke_link"])
        let create = try #require(requests.first)
        #expect(create["api"] as? String == "https://platform.invalid")
        #expect(create["credential"] as? String == "access")
        #expect(create["team"] as? String == "team_1")
        let createArgs = try #require(create["args"] as? [String: Any])
        #expect(createArgs["machine"] as? String == "vm_abc")
        #expect(createArgs["port"] as? Int == 3000)
        #expect(createArgs.count == 2, "no expiry or use cap unless asked")
        let revokeArgs = try #require(requests.last?["args"] as? [String: Any])
        #expect(revokeArgs["machine"] as? String == "vm_abc")
        #expect(revokeArgs["port"] as? Int == 3000)
        #expect(revokeArgs["linkId"] as? String == "link_123")
    }

    @Test func aCustomExpiryAndUseCapGoToTheDaemon() async throws {
        let daemon = daemon()
        _ = try await api(daemon).createPreviewShareLink("vm_abc", port: 3000, expiresAt: 1_700_000_100_000, maxUses: 3)
        let args = try #require(daemon.args("previews.create_link").first)
        #expect(args["expiresAt"] as? Int == 1_700_000_100_000)
        #expect(args["maxUses"] as? Int == 3)
    }

    /// A refusal the daemon reads from the platform is the same ``CloudAPIError`` the app showed before.
    @Test func aPlatformRefusalIsTheSameError() async throws {
        let daemon = FakeDaemon { _, _, _ in #"{"ok":false,"error":{"kind":"http","status":404,"code":"machine.preview_not_found","message":"no preview"}}"# }
        await #expect(throws: CloudAPIError.http(status: 404, code: "machine.preview_not_found", message: "no preview")) {
            _ = try await api(daemon).createPreviewShareLink("vm_abc", port: 3000)
        }
    }

    /// Copy Link and `cloud machine-link --port` get their URL here: the platform's share link for the
    /// port, https only; with no platform preview origin, no link and no request.
    @MainActor @Test func aPortLinkIsThePlatformsShareLink() async throws {
        let daemon = daemon()
        let api = try api(daemon)
        let names = CloudPortNames(name: "devbox", id: "vm_abc", port: 3000)
        let created = try await CloudHandlers.previewShareLink(api, machine: "vm_abc", port: 3000, names: names)
        #expect(created.url == "https://preview.example/?cmux_share=secret")
        #expect(daemon.args("previews.create_link").count == 1)

        do {
            _ = try await CloudHandlers.previewShareLink(nil, machine: "vm_abc", port: 3000, names: names)
            Issue.record("a link with no preview API")
        } catch let failure as ActionFailure {
            #expect(failure.message == CloudPortStrings.noLink(names))
        }
        #expect(daemon.requests.count == 1)
    }
}
