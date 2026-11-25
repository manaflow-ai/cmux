@testable import CmuxNextCloud
import Foundation
import Testing

/// The Cloud network list is the daemon's `vm.networks` (cmux-platform's `GET /v1/host/network/target`, read in
/// cmux-cloud-api `network.rs`) on the Worker machines client, sent as this Mac's install (auth `worker`; the route
/// refuses a Stack session), never classic `/api/vm/network`: the team's one network (its team id, its mesh as
/// `meshId`), or none before it has a mesh (Rust answers `[]` for the 404).
@Suite(.serialized)
struct CloudNetworkListTests {
    actor Seen {
        var input: Data?
        func saw(_ data: Data) { input = data }
    }

    private func worker(answering body: String, _ seen: Seen = Seen()) throws -> CloudDaemon {
        var api = CloudDaemon.workerMachines(baseURL: try #require(URL(string: "https://worker.invalid")),
                                                accessToken: { "session" }, teamID: { "team_1" }, installToken: { "install" })
        api.daemonCall = { input, _ in
            await seen.saw(input)
            return Data(#"{"ok":true,"body":\#(body)}"#.utf8)
        }
        return api
    }

    @Test func theTeamsMeshIsItsNetworkReadAsTheInstall() async throws {
        let seen = Seen()
        let networks = try await worker(answering: #"[{"id":"team_aaaaaaaaaaaaaaaaaaaa","meshId":"mesh_0123456789abcdefghjkmnpqrs","cidr":"10.128.16.0/20","cidrV6":null,"scope":"team"}]"#, seen).listNetworks()
        // The id is the team's, so `cloud network-list` output feeds `cloud tunnel attach` as it is.
        #expect(networks == [CloudNetwork(id: "team_aaaaaaaaaaaaaaaaaaaa", meshId: "mesh_0123456789abcdefghjkmnpqrs",
                                          cidr: "10.128.16.0/20", cidrV6: nil, scope: "team")])
        let input = try #require(await seen.input)
        let request = try #require(try JSONSerialization.jsonObject(with: input) as? [String: Any])
        #expect(request["call"] as? String == "vm.networks")
        #expect(request["auth"] as? String == "worker")
        #expect(request["credential"] as? String == "install")
        #expect(request["team"] as? String == "team_1")
        #expect(request["api"] as? String == "https://worker.invalid")
    }

    @Test func aTeamWithNoMeshYetHasNoNetwork() async throws {
        #expect(try await worker(answering: "[]").listNetworks().isEmpty)
    }

    @Test func aClassicClientSendsNothing() async throws {
        let seen = Seen()
        var classic = CloudDaemon(configuration: CloudConfiguration.resolve(bundleID: nil, bundled: ["CMUX_VM_API_BASE_URL": "https://vm-api.standin.invalid"],
                                                                                process: [:], isDebugBuild: true), tokens: { ("access", "refresh") },
                                     teamID: { "team_1" })
        classic.daemonCall = { input, _ in
            await seen.saw(input)
            return Data()
        }
        await #expect(throws: CloudAPIError.self) { try await classic.listNetworks() }
        let sent = await seen.input
        #expect(sent == nil)
    }
}
