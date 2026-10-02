@testable import CmuxNextCloud
import Foundation
import Testing

@Suite(.serialized) struct CloudNetworkAPITests {
    private static func api() -> CloudAPIClient {
        let configuration = CloudConfiguration.resolve(bundleID: "test.network", bundled: ["CMUX_VM_API_BASE_URL": "https://network.test"], process: [:], isDebugBuild: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudFileStubProtocol.self]
        return CloudAPIClient(configuration: configuration, tokens: { ("a", "r") }, teamID: { nil }, session: URLSession(configuration: config))
    }

    @Test func tunnelMutationsUseTypedRoutes() async throws {
        CloudFileStubProtocol.seen.withLock { $0 = [] }
        CloudFileStubProtocol.reply.withLock { $0 = Data(#"{"tunnelId":"tun-1","networkId":"vpc-1","addressV4":"10.0.0.2"}"#.utf8) }
        _ = try await Self.api().attachTunnelNetwork(deviceFingerprint: "mac-1", networkID: "vpc-1")
        _ = try await Self.api().detachTunnelNetwork(deviceFingerprint: "mac-1", networkID: "vpc-1")
        _ = try await Self.api().rotateTunnelKey(deviceFingerprint: "mac-1", publicKey: String(repeating: "A", count: 43) + "=")
        #expect(CloudFileStubProtocol.seen.withLock { $0.map(\.path) } == ["/api/vm/tunnel/network/attach", "/api/vm/tunnel/network/detach", "/api/vm/tunnel/network/rotate-key"])
    }

    @Test func firewallListEscapesResourceSelectors() async throws {
        CloudFileStubProtocol.seen.withLock { $0 = [] }
        CloudFileStubProtocol.reply.withLock { $0 = Data(#"{"rules":[{"id":"rule-1","action":"allow","source":{"public":true},"destination":{"vpcId":"vpc-1","port":443,"protocol":"tcp"}}]}"#.utf8) }
        let rules = try await Self.api().listFirewallRules(vpcID: "vpc/a&b")
        #expect(rules.first?.id == "rule-1")
        #expect(CloudFileStubProtocol.seen.withLock { $0.first?.query?.contains("vpcId=vpc%2Fa%26b") == true })
    }
}
