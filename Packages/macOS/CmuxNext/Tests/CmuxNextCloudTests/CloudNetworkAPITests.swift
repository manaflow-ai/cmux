@testable import CmuxNextCloud
import Foundation
import Synchronization
import Testing

final class CloudNetworkStubProtocol: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable { var path: String; var query: String? }
    static let seen = Mutex<[Seen]>([])
    static let reply = Mutex(Data("{}".utf8))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.withLock { $0.append(Seen(path: request.url?.path ?? "", query: request.url?.query)) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.reply.withLock { $0 })
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct CloudNetworkAPITests {
    private static func api() -> CloudAPIClient {
        let configuration = CloudConfiguration.resolve(bundleID: "test.network", bundled: ["CMUX_VM_API_BASE_URL": "https://network.test"], process: [:], isDebugBuild: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudNetworkStubProtocol.self]
        return CloudAPIClient(configuration: configuration, tokens: { ("a", "r") }, teamID: { nil }, session: URLSession(configuration: config))
    }

    @Test func tunnelMutationsUseTypedRoutes() async throws {
        CloudNetworkStubProtocol.seen.withLock { $0 = [] }
        CloudNetworkStubProtocol.reply.withLock { $0 = Data(#"{"tunnelId":"tun-1","networkId":"vpc-1","addressV4":"10.0.0.2"}"#.utf8) }
        _ = try await Self.api().attachTunnelNetwork(deviceFingerprint: "mac-1", networkID: "vpc-1")
        _ = try await Self.api().detachTunnelNetwork(deviceFingerprint: "mac-1", networkID: "vpc-1")
        _ = try await Self.api().rotateTunnelKey(deviceFingerprint: "mac-1", publicKey: String(repeating: "A", count: 43) + "=")
        #expect(CloudNetworkStubProtocol.seen.withLock { $0.map(\.path) } == ["/api/vm/tunnel/network/attach", "/api/vm/tunnel/network/detach", "/api/vm/tunnel/network/rotate-key"])
    }

    @Test func firewallListEscapesResourceSelectors() async throws {
        CloudNetworkStubProtocol.seen.withLock { $0 = [] }
        CloudNetworkStubProtocol.reply.withLock { $0 = Data(#"{"rules":[{"id":"rule-1","action":"allow","source":{"public":true},"destination":{"vpcId":"vpc-1","port":443,"protocol":"tcp"}}]}"#.utf8) }
        let rules = try await Self.api().listFirewallRules(vpcID: "vpc/a&b")
        #expect(rules.first?.id == "rule-1")
        #expect(rules.first?.source.isPublic == true)
        #expect(rules.first?.destination.protocolName == "tcp")
        #expect(CloudNetworkStubProtocol.seen.withLock { $0.first?.query?.contains("vpcId=vpc%2Fa%26b") == true })
    }

    @Test func domainAndPublicationListsUseRedactedRoutes() async throws {
        CloudNetworkStubProtocol.seen.withLock { $0 = [] }
        CloudNetworkStubProtocol.reply.withLock {
            $0 = Data(#"{"domains":[{"id":"dom-1","hostname":"example.test","verificationState":"verified","certificateState":"active","publications":[{"id":"pub-1","hostname":"app.example.test","state":"active"}]}],"publications":[{"id":"pub-1","hostname":"app.example.test","url":"https://app.example.test","domainKind":"custom","vmId":"vm-1","port":3000,"publicPort":443,"targetPort":3000,"protocol":"https","accessMode":"personal","teamId":null,"state":"active","routingRevision":2,"verification":{"verificationId":"ver-1","domain":"example.test","state":"verified"}}]}"#.utf8)
        }
        let api = Self.api()
        let domains = try await api.listDomains()
        let publications = try await api.listPublications()
        #expect(domains.first?.hostname == "example.test")
        #expect(domains.first?.verificationState == "verified")
        #expect(domains.first?.certificateState == "active")
        #expect(domains.first?.publications?.first?.state == "active")
        #expect(publications.first?.hostname == "app.example.test")
        #expect(publications.first?.state == "active")
        #expect(publications.first?.url == "https://app.example.test")
        #expect(publications.first?.verification?.state == "verified")
        #expect(CloudNetworkStubProtocol.seen.withLock { $0.map(\.path) } == ["/api/vm/domains", "/api/vm/publications"])
    }
}
