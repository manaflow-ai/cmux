import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// Provision API on Machine and the API key actions (#25594): the routes and bodies the client
/// sends, the server answers they decode, and the fields a CLI or agent run gets back.
@Suite struct CloudAPIClientProvisionAPITests {
    static let key = #"{"id":"key-1","publicationId":"pub-1","name":"agent","hint":"wxyz","createdAt":"2026-10-26T12:00:00.000Z","expiresAt":null,"revokedAt":null}"#

    /// The daemon's `cloud.vm.*` answers (cmux-cloud-api `classic.rs` already took `apiKeys` and `apiKey` out).
    static func api() -> FakeCloudAPI {
        FakeCloudAPI { call in
            switch call.operation {
            case "cloud.vm.provision_api":
                FakeCloudAPI.json(#"{"url":"https://hello--owner--3000.cmux.sh","publication":{"id":"pub-1","hostname":"hello--owner--3000.cmux.sh","url":"https://hello--owner--3000.cmux.sh","vmId":"vm-1","port":3000,"accessMode":"personal","state":"active"},"apiKey":\#(key),"token":"cmux_api_secret","cookieName":"__Host-cmux-api-key","cookie":"__Host-cmux-api-key=cmux_api_secret"}"#)
            case "cloud.vm.publication_api_keys":
                FakeCloudAPI.json("[\(key)]")
            default:
                FakeCloudAPI.json(#"{"id":"key-1","publicationId":"pub-1","name":"agent","hint":"wxyz","createdAt":"2026-10-26T12:00:00.000Z","expiresAt":null,"revokedAt":"2026-10-26T12:05:00.000Z"}"#)
            }
        }
    }

    @Test func provisionPublishesThePortAndAnswersTheURLAndKeyOnce() async throws {
        let fake = Self.api()
        let provisioned = try await fake.classic().provisionAPI(machineID: "vm-1", port: 3000, keyName: "agent")
        #expect(fake.operations == ["cloud.vm.provision_api"])
        let args = try #require(fake.seen.first?.args)
        #expect(args["vmId"]?.stringValue == "vm-1")
        #expect(args["port"]?.intValue == 3000)
        #expect(args["keyName"]?.stringValue == "agent")
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

    @Test func listAndRevokeAddressThePublicationAndKey() async throws {
        let fake = Self.api()
        let api = fake.classic()
        let keys = try await api.listPublicationAPIKeys("hello--owner--3000.cmux.sh")
        #expect(keys.map(\.id) == ["key-1"])
        #expect(keys.first?.hint == "wxyz")
        let revoked = try await api.revokePublicationAPIKey("pub-1", keyID: "key-1")
        #expect(revoked.revokedAt == "2026-10-26T12:05:00.000Z")
        #expect(fake.operations == ["cloud.vm.publication_api_keys", "cloud.vm.revoke_publication_api_key"])
        #expect(fake.seen.map { $0.args["publication"]?.stringValue } == ["hello--owner--3000.cmux.sh", "pub-1"])
        #expect(fake.seen.last?.args["keyId"]?.stringValue == "key-1")
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
