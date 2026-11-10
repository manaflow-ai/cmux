import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCloud
import CmuxNextWakeups
import Foundation
import Testing

/// Provision API on Machine and the API key actions (#25594): the daemon calls the client makes
/// (cmux-cloud-api `previews.rs` sends the routes), the answers they decode, and the fields a CLI or
/// agent run gets back.
struct CloudAPIClientProvisionAPITests {
    static let key = #"{"id":"key-1","publicationId":"vm_abc:3000","name":"agent","hint":"wxyz","createdAt":"2026-10-26T12:00:00.000Z","expiresAt":null,"revokedAt":null}"#
    static let publication = #"{"id":"vm_abc:3000","hostname":"p3000-abc.preview.test","url":"https://p3000-abc.preview.test","domainKind":"managed","vmId":"vm_abc","port":3000,"targetPort":3000,"protocol":"https","accessMode":"personal","teamId":"team-1","state":"active"}"#

    private func fake() -> CloudDaemonFake {
        CloudDaemonFake { operation, _ in
            switch operation {
            case "cloud.vm.provision_api":
                CloudDaemonFake.value(#"{"url":"https://p3000-abc.preview.test","publication":\#(Self.publication),"apiKey":\#(Self.key),"token":"k1.secret","cookieName":"__Host-cmux-preview","cookie":"__Host-cmux-preview=k1.secret"}"#)
            case "cloud.vm.publications": CloudDaemonFake.read("[\(Self.publication)]")
            case "cloud.vm.domains":
                CloudDaemonFake.read(#"[{"id":"preview.test","hostname":"preview.test","kind":"managed","verificationState":"verified","certificateState":"managed","publications":[]}]"#)
            case "cloud.vm.publication_api_keys": CloudDaemonFake.read("[\(Self.key)]")
            default:
                CloudDaemonFake.value(#"{"id":"key-1","publicationId":"vm_abc:3000","name":"agent","hint":"wxyz","createdAt":"2026-10-26T12:00:00.000Z","expiresAt":null,"revokedAt":"2026-10-26T12:05:00.000Z"}"#)
            }
        }
    }

    /// The app's preview client (CloudService.previewAPI): the person's session at the platform origin.
    private func api(_ fake: CloudDaemonFake) throws -> CloudAPIClient {
        CloudAPIClient.workerMachines(baseURL: try #require(URL(string: "https://worker.invalid")), accessToken: { "access" },
                                      teamID: { "team-1" }, daemon: fake.daemon, work: BackgroundWork())
            .previewClient(baseURL: try #require(URL(string: "https://platform.invalid")))
    }

    @Test func provisionPublishesThePortAndAnswersTheURLAndKeyOnce() async throws {
        let fake = fake()
        let provisioned = try await api(fake).provisionAPI(machineID: "vm_abc", port: 3000, keyName: "agent")
        #expect(fake.sent.map(\.operation) == ["cloud.vm.provision_api"])
        let sent = try #require(fake.sent.first)
        #expect(sent.mutation && sent.params["api"] as? String == "https://platform.invalid")
        #expect(sent.args["machine"] as? String == "vm_abc" && sent.args["port"] as? Int == 3000 && sent.args["keyName"] as? String == "agent")

        let fields = CloudHandlers.machineFields("vm_abc", provisioned.actionFields.mapValues(ActionResultValue.string))
        #expect(fields["url"] == .string("https://p3000-abc.preview.test"))
        #expect(fields["key"] == .string("k1.secret"))
        #expect(fields["cookie"] == .string("__Host-cmux-preview=k1.secret"))
        #expect(fields["api_key_id"] == .string("key-1"))
        #expect(fields["publication_id"] == .string("vm_abc:3000"))
        #expect(fields["access"] == .string("personal"))
        #expect(fields["target"] == .string("machine:vm_abc"))
        // The person's sheet carries the same URL, key and a working request.
        let text = CloudStrings.provisionedAPI(url: provisioned.url, key: provisioned.token, cookie: provisioned.cookie)
        #expect(text.contains("curl -H 'Cookie: __Host-cmux-preview=k1.secret' https://p3000-abc.preview.test"))
    }

    @Test func listAndRevokeNameThePublicationByIDOrHostname() async throws {
        let fake = fake()
        let api = try api(fake)
        let keys = try await api.listPublicationAPIKeys("p3000-abc.preview.test")
        #expect(keys.map(\.id) == ["key-1"])
        #expect(keys.first?.hint == "wxyz")
        let revoked = try await api.revokePublicationAPIKey("vm_abc:3000", keyID: "key-1")
        #expect(revoked.revokedAt == "2026-10-26T12:05:00.000Z")
        #expect(fake.sent.map(\.operation) == ["cloud.vm.publication_api_keys", "cloud.vm.revoke_publication_api_key"])
        #expect(fake.sent.first?.args["publication"] as? String == "p3000-abc.preview.test")
        #expect(fake.sent.last?.args["publication"] as? String == "vm_abc:3000" && fake.sent.last?.args["keyId"] as? String == "key-1")
    }

    @Test func domainsAndPublicationsComeFromThePlatform() async throws {
        let fake = fake()
        let api = try api(fake)
        #expect(try await api.listDomains().map(\.hostname) == ["preview.test"])
        let publications = try await api.listPublications()
        #expect(publications.map(\.id) == ["vm_abc:3000"])
        #expect(publications.first?.accessMode == "personal")
        #expect(fake.sent.map(\.operation) == ["cloud.vm.domains", "cloud.vm.publications"])
    }

    /// No platform preview origin: the classic client refuses and sends nothing.
    @Test func aClassicClientSendsNothing() async throws {
        let fake = fake()
        let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
                                                       process: [:], isDebugBuild: true)
        let classic = CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { "team-1" }, daemon: fake.daemon)
        await #expect(throws: CloudAPIError.http(status: 501, code: "machine.previews_unsupported", message: nil)) {
            try await classic.listPublications()
        }
        await #expect(throws: CloudAPIError.self) { try await classic.provisionAPI(machineID: "vm_abc", port: 3000) }
        #expect(fake.sent.isEmpty)
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
