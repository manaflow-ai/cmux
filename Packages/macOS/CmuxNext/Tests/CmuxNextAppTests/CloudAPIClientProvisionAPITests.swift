import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// Provision API on Machine and the API key actions (#25594): the routes and bodies the client
/// sends, the server answers they decode, and the fields a CLI or agent run gets back.
/// The routes and bodies are cmux-tui's (`cli/cloud_api/tests.rs`); this checks what the app hands it.
@Suite(.serialized)
struct CloudAPIClientProvisionAPITests {
    static let key = #"{"id":"key-1","publicationId":"pub-1","name":"agent","hint":"wxyz","createdAt":"2026-10-26T12:00:00.000Z","expiresAt":null,"revokedAt":null}"#
    static let provisioned = #"{"ok":true,"body":{"url":"https://hello--owner--3000.cmux.sh","publication":{"id":"pub-1","hostname":"hello--owner--3000.cmux.sh","url":"https://hello--owner--3000.cmux.sh","vmId":"vm-1","port":3000,"accessMode":"personal","state":"active"},"apiKey":\#(Self.key),"token":"cmux_api_secret","cookieName":"__Host-cmux-api-key","cookie":"__Host-cmux-api-key=cmux_api_secret"}}"#

    @Test func provisionPublishesThePortAndAnswersTheURLAndKeyOnce() async throws {
        let cmux = try FakeBundledCmux(answer: Self.provisioned)
        defer { cmux.remove() }
        let provisioned = try await cmux.classic().provisionAPI(machineID: "vm-1", port: 3000, keyName: "agent")
        #expect(cmux.calls == ["vm.provision_api"])
        let args = try #require(cmux.request(1)["args"] as? [String: Any])
        #expect(args["vmId"] as? String == "vm-1")
        #expect(args["port"] as? Int == 3000)
        #expect(args["keyName"] as? String == "agent")
        #expect(args["accessMode"] == nil)

        let fields = CloudHandlers.machineFields("vm-1", provisioned.actionFields.mapValues(ActionResultValue.string))
        #expect(fields["url"] == .string("https://hello--owner--3000.cmux.sh"))
        #expect(fields["key"] == .string("cmux_api_secret"))
        #expect(fields["cookie"] == .string("__Host-cmux-api-key=cmux_api_secret"))
        #expect(fields["api_key_id"] == .string("key-1"))
        #expect(fields["publication_id"] == .string("pub-1"))
        #expect(fields["access"] == .string("personal"))
        #expect(fields["target"] == .string("machine:vm-1"))
        // The person's sheet carries the same URL, key and a working request.
        let text = CloudStrings.provisionedAPI(url: provisioned.url, key: provisioned.token, cookie: provisioned.cookie)
        #expect(text.contains("curl -H 'Cookie: __Host-cmux-api-key=cmux_api_secret' https://hello--owner--3000.cmux.sh"))
    }

    @Test func listAndRevokeNameThePublicationAndKey() async throws {
        let cmux = try FakeBundledCmux()
        defer { cmux.remove() }
        try cmux.answer(1, #"{"ok":true,"body":[\#(Self.key)]}"#)
        try cmux.answer(2, #"{"ok":true,"body":{"id":"key-1","publicationId":"pub-1","name":"agent","hint":"wxyz","createdAt":"2026-10-26T12:00:00.000Z","expiresAt":null,"revokedAt":"2026-10-26T12:05:00.000Z"}}"#)
        let api = cmux.classic()
        let keys = try await api.listPublicationAPIKeys("hello--owner--3000.cmux.sh")
        #expect(keys.map(\.id) == ["key-1"])
        #expect(keys.first?.hint == "wxyz")
        let revoked = try await api.revokePublicationAPIKey("pub-1", keyID: "key-1")
        #expect(revoked.revokedAt == "2026-10-26T12:05:00.000Z")
        #expect(cmux.calls == ["vm.publication_api_keys", "vm.revoke_publication_api_key"])
        #expect((cmux.request(1)["args"] as? [String: Any])?["publication"] as? String == "hello--owner--3000.cmux.sh")
        let revoke = try #require(cmux.request(2)["args"] as? [String: Any])
        #expect(revoke["publication"] as? String == "pub-1")
        #expect(revoke["keyId"] as? String == "key-1")
    }

    @Test func theActionsAreCatalogedForTheCLIAndAgents() throws {
        let catalog = ActionCatalog.all
        let provision = try #require(catalog.first { $0.id == "cloudProvisionAPI" })
        #expect(provision.cliName == "cloud provision-api")
        #expect(provision.targets == [.machine])
        #expect(provision.waitsForResult)
        #expect(provision.arguments.map(\.name) == ["port", "name"])
        let revoke = try #require(catalog.first { $0.id == "cloudAPIKeyRevoke" })
        #expect(revoke.isDestructive)
        #expect(revoke.cliName == "cloud api-key-revoke")
        #expect(catalog.first { $0.id == "cloudAPIKeyList" }?.waitsForResult == true)
    }
}
