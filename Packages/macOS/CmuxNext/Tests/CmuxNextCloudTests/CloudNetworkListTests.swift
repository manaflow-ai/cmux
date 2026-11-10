@testable import CmuxNextCloud
import Foundation
import Testing

/// The Cloud network list is the daemon's `cloud.vm.networks` (cmux-platform's
/// `GET /v1/host/network/target`) on the Worker machines client, sent as this Mac's install (the
/// route refuses a Stack session): the team's one network, its id the team's.
struct CloudNetworkListTests {
    @Test func theTeamsMeshIsItsNetworkReadAsTheInstall() async throws {
        let fake = CloudDaemonFake { _, _ in
            CloudDaemonFake.read(#"[{"id":"team_aaaaaaaaaaaaaaaaaaaa","meshId":"mesh_0123456789abcdefghjkmnpqrs","cidr":"10.128.16.0/20","cidrV6":null,"scope":"team"}]"#)
        }
        let worker = CloudAPIClient.workerMachines(baseURL: try #require(URL(string: "https://worker.invalid")),
                                                   accessToken: { "session" }, teamID: { "team_1" }, daemon: fake.daemon,
                                                   installToken: { "install" })
        let networks = try await worker.listNetworks()
        // The id is the team's, so `cloud network-list` output feeds `cloud tunnel attach` as it is.
        #expect(networks == [CloudNetwork(id: "team_aaaaaaaaaaaaaaaaaaaa", meshId: "mesh_0123456789abcdefghjkmnpqrs",
                                          cidr: "10.128.16.0/20", cidrV6: nil, scope: "team")])
        let sent = try #require(fake.sent.first)
        #expect(fake.sent.count == 1)
        #expect(sent.operation == "cloud.vm.networks" && !sent.mutation)
        #expect(sent.params["api"] as? String == "https://worker.invalid")
        #expect(sent.params["auth"] as? String == "worker")
        #expect(sent.params["access_token"] as? String == "install")
        #expect(sent.params["team"] as? String == "team_1")
        #expect(sent.params["refresh_token"] == nil)
    }

    @Test func aClassicClientSendsNothing() async throws {
        let fake = CloudDaemonFake()
        let classic = CloudAPIClient(configuration: CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
                                                                                    process: [:], isDebugBuild: true), tokens: { ("access", "refresh") },
                                     teamID: { "team_1" }, daemon: fake.daemon)
        await #expect(throws: CloudAPIError.self) { try await classic.listNetworks() }
        #expect(fake.sent.isEmpty)
    }
}
