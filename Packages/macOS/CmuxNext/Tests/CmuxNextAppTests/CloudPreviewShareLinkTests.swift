import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextCloudUI
import Foundation
import Testing

struct CloudPreviewShareLinkTests {
    static let link = #"{"link":{"linkId":"link_123","creator":"user_1","team":"team_1","machine":"vm_abc","port":3000,"hostname":"preview.example","ruleId":"rule_1","createdAt":1700000000000,"expiresAt":1700086400000,"maxUses":null,"redemptions":0,"revokedAt":null},"url":"https://preview.example/?cmux_share=secret"}"#

    private func fake() -> CloudDaemonFake {
        CloudDaemonFake { operation, _ in CloudDaemonFake.value(operation == "cloud.previews.create_link" ? Self.link : #"{"revoked":true}"#) }
    }

    private func api(_ fake: CloudDaemonFake) throws -> CloudAPIClient {
        CloudAPIClient.workerMachines(baseURL: try #require(URL(string: "https://worker.invalid")),
                                      accessToken: { "access" }, teamID: { "team_1" }, daemon: fake.daemon)
            .previewClient(baseURL: try #require(URL(string: "https://platform.invalid")))
    }

    @Test func createCopiesThePlatformLinkAndRevokeTargetsItsID() async throws {
        let fake = fake()
        let api = try api(fake)
        let created = try await api.createPreviewShareLink("vm_abc", port: 3000)
        #expect(created.link.linkId == "link_123")
        #expect(created.url == "https://preview.example/?cmux_share=secret")
        #expect(created.link.maxUses == nil)
        let revoked = try await api.revokePreviewShareLink("vm_abc", port: 3000, linkID: created.link.linkId)
        #expect(revoked.revoked)

        #expect(fake.sent.map(\.operation) == ["cloud.previews.create_link", "cloud.previews.revoke_link"])
        let create = try #require(fake.sent.first)
        #expect(create.params["api"] as? String == "https://platform.invalid")
        #expect(create.params["auth"] as? String == "worker" && create.params["access_token"] as? String == "access")
        #expect(create.params["team"] as? String == "team_1")
        #expect(create.args.keys.sorted() == ["machine", "port"])
        let revoke = try #require(fake.sent.last)
        #expect(revoke.args["machine"] as? String == "vm_abc" && revoke.args["port"] as? Int == 3000)
        #expect(revoke.args["linkId"] as? String == "link_123")
    }

    /// Copy Link and `cloud machine-link --port` get their URL here: the platform's share link for the
    /// port, https only; with no platform preview origin, no link and no call.
    @MainActor @Test func aPortLinkIsThePlatformsShareLink() async throws {
        let fake = fake()
        let api = try api(fake)
        let names = CloudPortNames(name: "devbox", id: "vm_abc", port: 3000)
        let created = try await CloudHandlers.previewShareLink(api, machine: "vm_abc", port: 3000, names: names)
        #expect(created.url == "https://preview.example/?cmux_share=secret")
        #expect(fake.sent.map(\.operation) == ["cloud.previews.create_link"])

        do {
            _ = try await CloudHandlers.previewShareLink(nil, machine: "vm_abc", port: 3000, names: names)
            Issue.record("a link with no preview API")
        } catch let failure as ActionFailure {
            #expect(failure.message == CloudPortStrings.noLink(names))
        }
        #expect(fake.sent.count == 1)
    }
}
