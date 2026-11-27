import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCloud
import Foundation
import Testing

/// Provision API on Machine and the API key actions (#25594): the daemon calls the client sends
/// (cmux-cloud-api `previews.rs`'s `cloud.vm.*`), the platform answers they decode, and the fields a CLI or
/// agent run gets back.
@Suite(.serialized)
struct CloudAPIClientProvisionAPITests {
    typealias FakeDaemon = CloudAPIClientRunTests.FakeDaemon

    nonisolated static let key = #"{"id":"key-1","publicationId":"vm_abc:3000","name":"agent","hint":"wxyz","createdAt":"2026-10-26T12:00:00.000Z","expiresAt":null,"revokedAt":null}"#
    nonisolated static let publication = #"{"id":"vm_abc:3000","hostname":"p3000-abc.preview.test","url":"https://p3000-abc.preview.test","domainKind":"managed","vmId":"vm_abc","port":3000,"targetPort":3000,"protocol":"https","accessMode":"personal","teamId":"team-1","state":"active"}"#

    /// The daemon's answer bodies, as `previews.rs` gives them (the list calls answer the list, not its wrapper).
    private func daemon() -> FakeDaemon {
        FakeDaemon { call, _, _ in
            let body: String
            switch call {
            case "vm.provision_api":
                body = #"{"url":"https://p3000-abc.preview.test","publication":\#(Self.publication),"apiKey":\#(Self.key),"token":"k1.secret","cookieName":"__Host-cmux-preview","cookie":"__Host-cmux-preview=k1.secret"}"#
            case "vm.publications": body = "[\(Self.publication)]"
            case "vm.domains":
                body = #"[{"id":"preview.test","hostname":"preview.test","kind":"managed","verificationState":"verified","certificateState":"managed","publications":[]}]"#
            case "vm.publication_api_keys": body = "[\(Self.key)]"
            default:
                body = #"{"id":"key-1","publicationId":"vm_abc:3000","name":"agent","hint":"wxyz","createdAt":"2026-10-26T12:00:00.000Z","expiresAt":null,"revokedAt":"2026-10-26T12:05:00.000Z"}"#
            }
            return #"{"ok":true,"body":\#(body)}"#
        }
    }

    /// The app's preview client (CloudService.previewAPI): the person's session at the platform origin.
    private func api(_ daemon: FakeDaemon) throws -> CloudAPIClient {
        var worker = CloudAPIClient.workerMachines(baseURL: try #require(URL(string: "https://worker.invalid")), accessToken: { "access" },
                                                   teamID: { "team-1" })
        worker.daemon.daemonCall = { input, _ in try daemon.run(input) }
        return worker.previewClient(baseURL: try #require(URL(string: "https://platform.invalid")))
    }

    @Test func provisionPublishesThePortAndAnswersTheURLAndKeyOnce() async throws {
        let daemon = daemon()
        let provisioned = try await api(daemon).provisionAPI(machineID: "vm_abc", port: 3000, keyName: "agent")
        #expect(daemon.requests.map { $0["call"] as? String } == ["vm.provision_api"])
        #expect(daemon.requests.first?["api"] as? String == "https://platform.invalid")
        let args = try #require(daemon.args("vm.provision_api").first)
        #expect(args["machine"] as? String == "vm_abc")
        #expect(args["port"] as? Int == 3000)
        #expect(args["keyName"] as? String == "agent")
        #expect(args.count == 3)

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

    /// The daemon finds the publication's machine and port by its id or hostname; the app names it as given.
    @Test func listAndRevokeNameThePublicationByIDOrHostname() async throws {
        let daemon = daemon()
        let api = try api(daemon)
        let keys = try await api.listPublicationAPIKeys("p3000-abc.preview.test")
        #expect(keys.map(\.id) == ["key-1"])
        #expect(keys.first?.hint == "wxyz")
        let revoked = try await api.revokePublicationAPIKey("vm_abc:3000", keyID: "key-1")
        #expect(revoked.revokedAt == "2026-10-26T12:05:00.000Z")
        #expect(daemon.requests.map { $0["call"] as? String } == ["vm.publication_api_keys", "vm.revoke_publication_api_key"])
        #expect(daemon.args("vm.publication_api_keys").first?["publication"] as? String == "p3000-abc.preview.test")
        let revoke = try #require(daemon.args("vm.revoke_publication_api_key").first)
        #expect(revoke["publication"] as? String == "vm_abc:3000")
        #expect(revoke["keyId"] as? String == "key-1")
    }

    /// An unknown publication is the daemon's 404, the same error the app showed before.
    @Test func anUnknownPublicationIsNotFound() async throws {
        let daemon = FakeDaemon { _, _, _ in
            #"{"ok":false,"error":{"kind":"http","status":404,"code":"cloud.preview.not_found","message":"no such publication: vm_other:80"}}"#
        }
        await #expect(throws: CloudAPIError.http(status: 404, code: "cloud.preview.not_found", message: "no such publication: vm_other:80")) {
            try await api(daemon).listPublicationAPIKeys("vm_other:80")
        }
    }

    @Test func domainsAndPublicationsComeFromThePlatform() async throws {
        let daemon = daemon()
        let api = try api(daemon)
        #expect(try await api.listDomains().map(\.hostname) == ["preview.test"])
        let publications = try await api.listPublications()
        #expect(publications.map(\.id) == ["vm_abc:3000"])
        #expect(publications.first?.accessMode == "personal")
        #expect(daemon.requests.map { $0["call"] as? String } == ["vm.domains", "vm.publications"])
    }

    /// No platform preview origin: the classic client refuses and sends nothing.
    @Test func aClassicClientSendsNothing() async throws {
        let daemon = daemon()
        let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
                                                       process: [:], isDebugBuild: true)
        var classic = CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { "team-1" })
        classic.daemon.daemonCall = { input, _ in try daemon.run(input) }
        await #expect(throws: CloudAPIError.http(status: 501, code: "machine.previews_unsupported", message: nil)) {
            try await classic.listPublications()
        }
        await #expect(throws: CloudAPIError.self) { try await classic.provisionAPI(machineID: "vm_abc", port: 3000) }
        #expect(daemon.requests.isEmpty)
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
