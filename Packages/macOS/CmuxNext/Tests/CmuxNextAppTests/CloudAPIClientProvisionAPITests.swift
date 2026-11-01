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
            let key = #"{"id":"key-1","publicationId":"pub-1","name":"agent","hint":"wxyz","createdAt":"2026-10-26T12:00:00.000Z","expiresAt":null,"revokedAt":null}"#
            let answer: String
            switch (request.httpMethod ?? "", url.path) {
            case ("POST", "/api/vm/apis"):
                answer = #"{"url":"https://hello--owner--3000.cmux.sh","publication":{"id":"pub-1","hostname":"hello--owner--3000.cmux.sh","url":"https://hello--owner--3000.cmux.sh","vmId":"vm-1","port":3000,"accessMode":"personal","state":"active"},"apiKey":\#(key),"token":"cmux_api_secret","cookieName":"__Host-cmux-api-key","cookie":"__Host-cmux-api-key=cmux_api_secret"}"#
            case ("GET", _):
                answer = #"{"apiKeys":[\#(key)]}"#
            default:
                answer = #"{"apiKey":{"id":"key-1","publicationId":"pub-1","name":"agent","hint":"wxyz","createdAt":"2026-10-26T12:00:00.000Z","expiresAt":null,"revokedAt":"2026-10-26T12:05:00.000Z"}}"#
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

    private func api() -> CloudAPIClient {
        let configuration = CloudConfiguration.resolve(
            bundleID: nil,
            bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
            process: [:],
            isDebugBuild: true
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [APIRoutes.self]
        return CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { "team-1" },
                              session: URLSession(configuration: sessionConfiguration))
    }

    @Test func provisionPublishesThePortAndAnswersTheURLAndKeyOnce() async throws {
        APIRoutes.seen = []
        let provisioned = try await api().provisionAPI(machineID: "vm-1", port: 3000, keyName: "agent")
        #expect(APIRoutes.seen.map(\.method) == ["POST"])
        #expect(APIRoutes.seen.map(\.path) == ["/api/vm/apis"])
        let body = try #require(APIRoutes.seen.first?.body)
        #expect(body["vmId"] as? String == "vm-1")
        #expect(body["port"] as? Int == 3000)
        #expect(body["name"] as? String == "agent")
        #expect(body["accessMode"] == nil)

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
        APIRoutes.seen = []
        let api = api()
        let keys = try await api.listPublicationAPIKeys("hello--owner--3000.cmux.sh")
        #expect(keys.map(\.id) == ["key-1"])
        #expect(keys.first?.hint == "wxyz")
        let revoked = try await api.revokePublicationAPIKey("pub-1", keyID: "key-1")
        #expect(revoked.revokedAt == "2026-10-26T12:05:00.000Z")
        #expect(APIRoutes.seen.map(\.method) == ["GET", "DELETE"])
        #expect(APIRoutes.seen.map(\.path) == [
            "/api/vm/publications/hello--owner--3000.cmux.sh/api-keys",
            "/api/vm/publications/pub-1/api-keys/key-1",
        ])
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
