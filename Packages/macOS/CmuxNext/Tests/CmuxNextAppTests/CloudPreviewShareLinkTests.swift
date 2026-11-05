@testable import CmuxNextCloud
import Foundation
import Testing

@Suite(.serialized)
struct CloudPreviewShareLinkTests {
    nonisolated final class PreviewLinksAPI: URLProtocol {
        nonisolated(unsafe) static var requests: [URLRequest] = []
        /// URLSession hands a protocol the body as `httpBodyStream`, not `httpBody`, so read it here.
        nonisolated(unsafe) static var bodies: [Data] = []

        static func body(of request: URLRequest) -> Data {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        }

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"]) else { return }
            Self.requests.append(request)
            Self.bodies.append(Self.body(of: request))
            let body: Data
            if request.httpMethod == "POST" {
                body = Data(#"{"link":{"linkId":"link_123","creator":"user_1","team":"team_1","machine":"vm_abc","port":3000,"hostname":"preview.example","ruleId":"rule_1","createdAt":1700000000000,"expiresAt":1700086400000,"maxUses":null,"redemptions":0,"revokedAt":null},"url":"https://preview.example/?cmux_share=secret"}"#.utf8)
            } else {
                body = Data(#"{"revoked":true}"#.utf8)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func session() -> URLSession {
        Self.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreviewLinksAPI.self]
        return URLSession(configuration: configuration)
    }

    private static func reset() {
        PreviewLinksAPI.requests = []
        PreviewLinksAPI.bodies = []
    }

    @Test func createCopiesThePlatformLinkAndRevokeTargetsItsID() async throws {
        let api = CloudAPIClient.workerMachines(baseURL: try #require(URL(string: "https://worker.invalid")),
                                                accessToken: { "access" }, teamID: { "team_1" }, session: session())
            .previewClient(baseURL: try #require(URL(string: "https://platform.invalid")))

        let created = try await api.createPreviewShareLink("vm_abc", port: 3000)
        #expect(created.link.linkId == "link_123")
        #expect(created.url == "https://preview.example/?cmux_share=secret")
        #expect(created.link.maxUses == nil)
        let revoked = try await api.revokePreviewShareLink("vm_abc", port: 3000, linkID: created.link.linkId)
        #expect(revoked.revoked)

        let requests = PreviewLinksAPI.requests
        #expect(requests.count == 2)
        let create = try #require(requests.first)
        #expect(create.httpMethod == "POST")
        #expect(create.url?.absoluteString == "https://platform.invalid/v1/cloud/machines/vm_abc/previews/3000/links")
        #expect(create.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(create.value(forHTTPHeaderField: "x-cmux-team") == "team_1")
        #expect(String(data: try #require(PreviewLinksAPI.bodies.first), encoding: .utf8) == "{}")
        let revoke = try #require(requests.last)
        #expect(revoke.httpMethod == "DELETE")
        #expect(revoke.url?.absoluteString == "https://platform.invalid/v1/cloud/machines/vm_abc/previews/3000/links/link_123")
    }
}
