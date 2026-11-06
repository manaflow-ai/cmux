import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextCloudUI
import Foundation
import Testing

@Suite(.serialized)
struct CloudPreviewShareLinkTests {
    static let created = #"{"ok":true,"body":{"link":{"linkId":"link_123","creator":"user_1","team":"team_1","machine":"vm_abc","port":3000,"hostname":"preview.example","ruleId":"rule_1","createdAt":1700000000000,"expiresAt":1700086400000,"maxUses":null,"redemptions":0,"revokedAt":null},"url":"https://preview.example/?cmux_share=secret"}}"#

    /// A stand-in cmux and a preview client over it; the route and headers are cmux-tui's (`cli/cloud_api/tests.rs`).
    private func previews() throws -> (FakeBundledCmux, CloudAPIClient) {
        let cmux = try FakeBundledCmux(answer: Self.created)
        let api = CloudAPIClient.workerMachines(baseURL: try #require(URL(string: "https://worker.invalid")),
                                                accessToken: { "access" }, teamID: { "team_1" }, cli: cmux.cli, sessions: nil)
            .previewClient(baseURL: try #require(URL(string: "https://platform.invalid")))
        return (cmux, api)
    }

    @Test func createCopiesThePlatformLinkAndRevokeTargetsItsID() async throws {
        let (cmux, api) = try previews()
        defer { cmux.remove() }
        try cmux.answer(2, #"{"ok":true,"body":{"revoked":true}}"#)
        let created = try await api.createPreviewShareLink("vm_abc", port: 3000)
        #expect(created.link.linkId == "link_123")
        #expect(created.url == "https://preview.example/?cmux_share=secret")
        #expect(created.link.maxUses == nil)
        let revoked = try await api.revokePreviewShareLink("vm_abc", port: 3000, linkID: created.link.linkId)
        #expect(revoked.revoked)
        #expect(cmux.calls == ["previews.create_link", "previews.revoke_link"])
        let create = cmux.request(1)
        #expect(create["api"] as? String == "https://platform.invalid")
        #expect(create["credential"] as? String == "access")
        #expect(create["team"] as? String == "team_1")
        let createArgs = try #require(create["args"] as? [String: Any])
        #expect(createArgs.keys.sorted() == ["machine", "port"], "a default link sends no expiry or use cap")
        let revokeArgs = try #require(cmux.request(2)["args"] as? [String: Any])
        #expect(revokeArgs["linkId"] as? String == "link_123")
        #expect(revokeArgs["port"] as? Int == 3000)
    }

    /// Copy Link and `cloud machine-link --port` get their URL here: the platform's share link for the
    /// port, https only; with no platform preview origin, no link and no request.
    @MainActor @Test func aPortLinkIsThePlatformsShareLink() async throws {
        let (cmux, api) = try previews()
        defer { cmux.remove() }
        let names = CloudPortNames(name: "devbox", id: "vm_abc", port: 3000)
        let created = try await CloudHandlers.previewShareLink(api, machine: "vm_abc", port: 3000, names: names)
        #expect(created.url == "https://preview.example/?cmux_share=secret")
        #expect(cmux.calls == ["previews.create_link"])

        do {
            _ = try await CloudHandlers.previewShareLink(nil, machine: "vm_abc", port: 3000, names: names)
            Issue.record("a link with no preview API")
        } catch let failure as ActionFailure {
            #expect(failure.message == CloudPortStrings.noLink(names))
        }
        #expect(cmux.runs == 1)
    }
}
