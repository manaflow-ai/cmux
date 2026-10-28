import CmuxNextCloud
import Foundation
import Testing

@Suite(.serialized)
struct CloudAPIClientSnapshotIdempotencyTests {
    nonisolated final class SnapshotAPI: URLProtocol {
        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            let hasKey = !(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "").isEmpty
            let status = hasKey ? 200 : 400
            let body = hasKey
                ? #"{"id":"snapshot-1","name":null,"createdAt":1777000000000}"#
                : #"{"error":"vm_idempotency_key_required"}"#
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Test func snapshotSendsAnIdempotencyKeyByDefault() async throws {
        let configuration = CloudConfiguration.resolve(
            bundleID: nil,
            bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
            process: [:],
            isDebugBuild: true
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SnapshotAPI.self]
        let api = CloudAPIClient(
            configuration: configuration,
            tokens: { ("access", "refresh") },
            teamID: { "team-1" },
            session: URLSession(configuration: sessionConfiguration)
        )

        #expect(try await api.snapshot("machine-1", name: nil).id == "snapshot-1")
    }
}
