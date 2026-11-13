import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// Provision API on Machine and the API key actions (#25594): the routes and bodies the client
/// sends, the server answers they decode, and the fields a CLI or agent run gets back.
@Suite(.serialized)
struct CloudAPIClientProvisionAPITests {
    nonisolated final class APIRoutes: URLProtocol {
        nonisolated(unsafe) static var seen: [(method: String, path: String, body: [String: Any]?)] = []

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            let body = Self.body(of: request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            Self.seen.append((request.httpMethod ?? "", url.path, body))
            let key = #"{"id":"key-1","publicationId":"vm_abc:3000","name":"agent","hint":"wxyz","createdAt":"2026-10-26T12:00:00.000Z","expiresAt":null,"revokedAt":null}"#
            let publication = #"{"id":"vm_abc:3000","hostname":"p3000-abc.preview.test","url":"https://p3000-abc.preview.test","domainKind":"managed","vmId":"vm_abc","port":3000,"targetPort":3000,"protocol":"https","accessMode":"personal","teamId":"team-1","state":"active"}"#
            let answer: String
            switch (request.httpMethod ?? "", url.path) {
            case ("POST", "/v1/cloud/machines/vm_abc/previews/3000/api-keys"):
                answer = #"{"url":"https://p3000-abc.preview.test","publication":\#(publication),"apiKey":\#(key),"token":"k1.secret","cookieName":"__Host-cmux-preview","cookie":"__Host-cmux-preview=k1.secret"}"#
            case ("GET", "/v1/cloud/previews"):
                answer = #"{"previews":[\#(publication)]}"#
            case ("GET", "/v1/cloud/domains"):
                answer = #"{"domains":[{"id":"preview.test","hostname":"preview.test","kind":"managed","verificationState":"verified","certificateState":"managed","publications":[]}]}"#
            case ("GET", _):
                answer = #"{"apiKeys":[\#(key)]}"#
            default:
                answer = #"{"apiKey":{"id":"key-1","publicationId":"vm_abc:3000","name":"agent","hint":"wxyz","createdAt":"2026-10-26T12:00:00.000Z","expiresAt":null,"revokedAt":"2026-10-26T12:05:00.000Z"}}"#
            }
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(answer.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        /// URLSession moves a body into a stream before a protocol sees it.
        private static func body(of request: URLRequest) -> Data? {
            if let data = request.httpBody { return data }
            guard let stream = request.httpBodyStream else { return nil }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    private func session() -> URLSession {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [APIRoutes.self]
        return URLSession(configuration: sessionConfiguration)
    }

    /// The app's preview client (CloudService.previewAPI): the person's session at the platform origin.
    private func api() throws -> CloudAPIClient {
        CloudAPIClient.workerMachines(baseURL: try #require(URL(string: "https://worker.invalid")), accessToken: { "access" },
                                      teamID: { "team-1" }, session: session())
            .previewClient(baseURL: try #require(URL(string: "https://platform.invalid")))
    }

    @Test func provisionPublishesThePortAndAnswersTheURLAndKeyOnce() async throws {
        APIRoutes.seen = []
        let provisioned = try await api().provisionAPI(machineID: "vm_abc", port: 3000, keyName: "agent")
        #expect(APIRoutes.seen.map(\.method) == ["POST"])
        #expect(APIRoutes.seen.map(\.path) == ["/v1/cloud/machines/vm_abc/previews/3000/api-keys"])
        let body = try #require(APIRoutes.seen.first?.body)
        #expect(body["name"] as? String == "agent")
        #expect(body.count == 1)

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

    @Test func listAndRevokeFindThePublicationsMachinePortByIDOrHostname() async throws {
        APIRoutes.seen = []
        let api = try api()
        let keys = try await api.listPublicationAPIKeys("p3000-abc.preview.test")
        #expect(keys.map(\.id) == ["key-1"])
        #expect(keys.first?.hint == "wxyz")
        let revoked = try await api.revokePublicationAPIKey("vm_abc:3000", keyID: "key-1")
        #expect(revoked.revokedAt == "2026-10-26T12:05:00.000Z")
        #expect(APIRoutes.seen.map(\.method) == ["GET", "GET", "GET", "DELETE"])
        #expect(APIRoutes.seen.map(\.path) == [
            "/v1/cloud/previews", "/v1/cloud/machines/vm_abc/previews/3000/api-keys",
            "/v1/cloud/previews", "/v1/cloud/machines/vm_abc/previews/3000/api-keys/key-1",
        ])
        await #expect(throws: CloudAPIError.self) { try await api.listPublicationAPIKeys("vm_other:80") }
    }

    @Test func domainsAndPublicationsComeFromThePlatform() async throws {
        APIRoutes.seen = []
        let api = try api()
        #expect(try await api.listDomains().map(\.hostname) == ["preview.test"])
        let publications = try await api.listPublications()
        #expect(publications.map(\.id) == ["vm_abc:3000"])
        #expect(publications.first?.accessMode == "personal")
        #expect(APIRoutes.seen.map(\.path) == ["/v1/cloud/domains", "/v1/cloud/previews"])
    }

    /// No platform preview origin: the classic client refuses and sends nothing to classic Cloud.
    @Test func aClassicClientSendsNothing() async throws {
        APIRoutes.seen = []
        let configuration = CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
                                                       process: [:], isDebugBuild: true)
        let classic = CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { "team-1" }, session: session())
        await #expect(throws: CloudAPIError.http(status: 501, code: "machine.previews_unsupported", message: nil)) {
            try await classic.listPublications()
        }
        await #expect(throws: CloudAPIError.self) { try await classic.provisionAPI(machineID: "vm_abc", port: 3000) }
        #expect(APIRoutes.seen.isEmpty)
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
