import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextDaemon
import Foundation
import Testing

@Suite struct CloudPreviewShareLinkTests {
    static func api() -> FakeCloudAPI {
        FakeCloudAPI { call in
            call.operation == "cloud.previews.create_link"
                ? FakeCloudAPI.json(#"{"link":{"linkId":"link_123","creator":"user_1","team":"team_1","machine":"vm_abc","port":3000,"hostname":"preview.example","ruleId":"rule_1","createdAt":1700000000000,"expiresAt":1700086400000,"maxUses":null,"redemptions":0,"revokedAt":null},"url":"https://preview.example/?cmux_share=secret"}"#)
                : FakeCloudAPI.json(#"{"revoked":true}"#)
        }
    }

    @Test func createCopiesThePlatformLinkAndRevokeTargetsItsID() async throws {
        let fake = Self.api()
        let api = fake.worker("https://worker.invalid").previewClient(baseURL: try #require(URL(string: "https://platform.invalid")))

        let created = try await api.createPreviewShareLink("vm_abc", port: 3000)
        #expect(created.link.linkId == "link_123")
        #expect(created.url == "https://preview.example/?cmux_share=secret")
        #expect(created.link.maxUses == nil)
        let revoked = try await api.revokePreviewShareLink("vm_abc", port: 3000, linkID: created.link.linkId)
        #expect(revoked.revoked)

        #expect(fake.operations == ["cloud.previews.create_link", "cloud.previews.revoke_link"])
        let create = try #require(fake.seen.first)
        #expect(create.field("api") == "https://platform.invalid")
        #expect(create.field("access_token") == "session-access")
        #expect(create.field("team") == "team_cmux")
        #expect(create.args == ["machine": .string("vm_abc"), "port": JSONValue(3000)])
        let revoke = try #require(fake.seen.last)
        #expect(revoke.args["linkId"]?.stringValue == "link_123")
        #expect(revoke.args["port"]?.intValue == 3000)
    }

    /// Copy Link and `cloud machine-link --port` get their URL here: the platform's share link for the
    /// port, https only; with no platform preview origin, no link and no request.
    @MainActor @Test func aPortLinkIsThePlatformsShareLink() async throws {
        let fake = Self.api()
        let api = fake.worker("https://worker.invalid").previewClient(baseURL: try #require(URL(string: "https://platform.invalid")))
        let names = CloudPortNames(name: "devbox", id: "vm_abc", port: 3000)
        let created = try await CloudHandlers.previewShareLink(api, machine: "vm_abc", port: 3000, names: names)
        #expect(created.url == "https://preview.example/?cmux_share=secret")
        #expect(fake.operations == ["cloud.previews.create_link"])

        do {
            _ = try await CloudHandlers.previewShareLink(nil, machine: "vm_abc", port: 3000, names: names)
            Issue.record("a link with no preview API")
        } catch let failure as ActionFailure {
            #expect(failure.message == CloudPortStrings.noLink(names))
        }
        #expect(fake.seen.count == 1)
    }
}
