@testable import CmuxNextCloud
import Foundation
import Testing

/// The Cloud network list is cmux-platform's `GET /v1/host/network/target` on the Worker machines
/// client, sent as this Mac's install (the route refuses a Stack session), never classic
/// `/api/vm/network`: the team's one mesh, or none before it has one (404).
@Suite(.serialized)
struct CloudNetworkListTests {
    nonisolated final class NetworkAPI: URLProtocol {
        nonisolated(unsafe) static var requests: [URLRequest] = []
        nonisolated(unsafe) static var status = 200

        override class func canInit(with _: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"]) else { return }
            Self.requests.append(request)
            let body = Self.status == 200
                ? #"{"team":"team_aaaaaaaaaaaaaaaaaaaa","tenant":"t1","project":"p1","origin":"https://vm.invalid","mesh":"mesh_0123456789abcdefghjkmnpqrs","ipv4_cidr":"10.128.16.0/20"}"#
                : #"{"code":"selector.not_found","message":"no available network mesh"}"#
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func worker(status: Int) throws -> CloudAPIClient {
        NetworkAPI.requests = []
        NetworkAPI.status = status
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkAPI.self]
        return CloudAPIClient.workerMachines(baseURL: try #require(URL(string: "https://worker.invalid")),
                                             accessToken: { "session" }, teamID: { "team_1" },
                                             session: URLSession(configuration: configuration),
                                             installToken: { "install" })
    }

    @Test func theTeamsMeshIsItsNetworkReadAsTheInstall() async throws {
        let networks = try await worker(status: 200).listNetworks()
        #expect(networks == [CloudNetwork(id: "mesh_0123456789abcdefghjkmnpqrs", cidr: "10.128.16.0/20", cidrV6: nil, scope: "team")])
        let request = try #require(NetworkAPI.requests.first)
        #expect(NetworkAPI.requests.count == 1)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://worker.invalid/v1/host/network/target")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer install")
        #expect(request.value(forHTTPHeaderField: "x-cmux-team") == "team_1")
        #expect(request.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == nil)
    }

    @Test func aTeamWithNoMeshYetHasNoNetwork() async throws {
        #expect(try await worker(status: 404).listNetworks().isEmpty)
    }

    @Test func aClassicClientSendsNothing() async throws {
        NetworkAPI.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkAPI.self]
        let classic = CloudAPIClient(configuration: CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
                                                                                    process: [:], isDebugBuild: true), tokens: { ("access", "refresh") },
                                     teamID: { "team_1" }, session: URLSession(configuration: configuration))
        await #expect(throws: CloudAPIError.self) { try await classic.listNetworks() }
        #expect(NetworkAPI.requests.isEmpty)
    }
}
