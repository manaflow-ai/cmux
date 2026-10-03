import CmuxCloud
import Foundation
import Testing

@Suite("Cloud port share service")
struct CloudPortShareServiceTests {
    @Test("creates a link with the server default and waits until it serves")
    func createsAndWaits() async throws {
        let api = FakePublishing(created: publication(state: "provisioning"), verifyStates: ["provisioning", "active"])
        let link = try await service(api).share(vmID: "brave-otter", port: 8000, teamID: "team-1")
        #expect(link.state == "active")
        #expect(await api.calls == [
            "list team-1",
            "create brave-otter:8000 team-1",
            "verify pub-1 team-1",
            "verify pub-1 team-1",
        ])
    }

    @Test("reuses the port's existing link instead of creating another")
    func reusesExisting() async throws {
        let api = FakePublishing(listed: [
            publication(id: "other", port: 3000, state: "active"),
            publication(id: "mine", state: "active"),
        ])
        let link = try await service(api).share(vmID: "brave-otter", port: 8000, teamID: "team-1")
        #expect(link.id == "mine")
        #expect(await api.calls == ["list team-1"])
    }

    @Test("does not reuse a link that is being removed")
    func skipsDisabling() async throws {
        let api = FakePublishing(
            listed: [publication(id: "old", state: "disabling")],
            created: publication(id: "new", state: "active")
        )
        let link = try await service(api).share(vmID: "brave-otter", port: 8000, teamID: nil)
        #expect(link.id == "new")
    }

    @Test("gives up with stillProvisioning once the waits run out")
    func timesOut() async {
        let api = FakePublishing(created: publication(state: "provisioning"), verifyStates: ["provisioning", "provisioning"])
        await #expect(throws: CloudPortShareError.stillProvisioning) {
            _ = try await service(api, delays: [.seconds(1), .seconds(1)]).share(vmID: "brave-otter", port: 8000, teamID: nil)
        }
    }

    @Test("an unavailable link is an error, not a copied dead URL")
    func unavailableFails() async {
        let api = FakePublishing(created: publication(state: "unavailable"))
        await #expect(throws: CloudPortShareError.unavailable(state: "unavailable")) {
            _ = try await service(api).share(vmID: "brave-otter", port: 8000, teamID: nil)
        }
    }

    @Test("waits past the edge's 503 before handing back an active link")
    func waitsForEdge() async throws {
        let api = FakePublishing(created: publication(state: "active"))
        let statuses = Statuses([503, nil, 302])
        let link = try await service(api, probe: { _ in await statuses.next() }).share(vmID: "brave-otter", port: 8000, teamID: nil)
        #expect(link.state == "active")
        #expect(await statuses.remaining == 0)
    }

    @Test("an edge that never answers is stillProvisioning, not a copied 503")
    func edgeNeverReady() async {
        let api = FakePublishing(created: publication(state: "active"))
        await #expect(throws: CloudPortShareError.stillProvisioning) {
            _ = try await service(api, delays: [.seconds(1)], probe: { _ in 503 }).share(vmID: "brave-otter", port: 8000, teamID: nil)
        }
    }

    private func service(
        _ api: FakePublishing,
        delays: [Duration] = [.seconds(1), .seconds(1), .seconds(1)],
        probe: @escaping CloudPortShareService.Probe = { _ in 302 }
    ) -> CloudPortShareService {
        CloudPortShareService(api: api, pollDelays: delays, sleep: { _ in }, probe: probe)
    }
}

private func publication(id: String = "pub-1", port: Int = 8000, state: String) -> VMPublication {
    VMPublication(
        id: id,
        hostname: "brave-otter--team--\(port).cmux.sh",
        url: "https://brave-otter--team--\(port).cmux.sh",
        domainKind: "managed",
        vmID: "brave-otter",
        port: port,
        accessMode: .team,
        teamID: "team-1",
        state: state,
        routingRevision: 1,
        verification: nil
    )
}

private actor Statuses {
    private var values: [Int?]
    init(_ values: [Int?]) { self.values = values }
    var remaining: Int { values.count }
    func next() -> Int? { values.isEmpty ? 302 : values.removeFirst() }
}

private actor FakePublishing: CloudPortPublishing {
    private(set) var calls: [String] = []
    private let listed: [VMPublication]
    private let created: VMPublication?
    private var verifyStates: [String]

    init(listed: [VMPublication] = [], created: VMPublication? = nil, verifyStates: [String] = []) {
        self.listed = listed
        self.created = created
        self.verifyStates = verifyStates
    }

    func listPublications(scopeTeamID: String?) async throws -> [VMPublication] {
        calls.append("list \(scopeTeamID ?? "-")")
        return listed
    }

    func createDefaultPublication(vmID: String, port: Int, scopeTeamID: String?) async throws -> VMPublication {
        calls.append("create \(vmID):\(port) \(scopeTeamID ?? "-")")
        return created!
    }

    func verifyPublication(id: String, scopeTeamID: String?) async throws -> VMPublication {
        calls.append("verify \(id) \(scopeTeamID ?? "-")")
        let state = verifyStates.isEmpty ? "active" : verifyStates.removeFirst()
        return publication(id: id, state: state)
    }

    func deletePublication(id: String, scopeTeamID: String?) async throws {
        calls.append("delete \(id) \(scopeTeamID ?? "-")")
    }
}
