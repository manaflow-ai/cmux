import CmuxCloud
import Foundation
import Testing

@Suite("Cloud port share service")
struct CloudPortShareServiceTests {
    @Test("creates a link with the server default and waits until it serves")
    func createsAndWaits() async throws {
        let api = FakePublishing(creates: [.row(publication(state: "provisioning")), .row(publication(state: "active"))])
        let link = try await service(api).share(vmID: "brave-otter", port: 8000, teamID: "team-1")
        #expect(link.state == "active")
        #expect(await api.calls == [
            "list team-1",
            "create brave-otter:8000 team-1",
            "create brave-otter:8000 team-1",
        ])
    }

    @Test("reuses the port's existing generated link instead of creating another")
    func reusesExisting() async throws {
        let api = FakePublishing(listed: [
            publication(id: "other", port: 3000, state: "active"),
            publication(id: "mine", state: "active"),
        ])
        let link = try await service(api).share(vmID: "brave-otter", port: 8000, teamID: "team-1")
        #expect(link.id == "mine")
        #expect(await api.calls == ["list team-1"])
    }

    @Test("a custom domain on the same port is not the link Share hands out")
    func ignoresCustomDomain() async throws {
        let api = FakePublishing(
            listed: [publication(id: "custom", state: "provisioning", domainKind: "custom")],
            creates: [.row(publication(id: "generated", state: "active"))]
        )
        let link = try await service(api).share(vmID: "brave-otter", port: 8000, teamID: nil)
        #expect(link.id == "generated")
    }

    @Test("a link being removed or a busy server only means not yet")
    func retriesTransientConflicts() async throws {
        let api = FakePublishing(
            listed: [publication(id: "old", state: "disabling")],
            creates: [.status(409), .status(503), .row(publication(id: "new", state: "active"))]
        )
        let link = try await service(api).share(vmID: "brave-otter", port: 8000, teamID: nil)
        #expect(link.id == "new")
    }

    @Test("an unavailable link is resumed by creating again, not given up on")
    func resumesUnavailable() async throws {
        let api = FakePublishing(
            listed: [publication(state: "unavailable")],
            creates: [.row(publication(state: "active"))]
        )
        let link = try await service(api).share(vmID: "brave-otter", port: 8000, teamID: nil)
        #expect(link.state == "active")
    }

    @Test("other server errors end the share")
    func otherErrorsThrow() async {
        let api = FakePublishing(creates: [.status(404)])
        await #expect(throws: VMClientError.self) {
            _ = try await service(api).share(vmID: "brave-otter", port: 8000, teamID: nil)
        }
    }

    @Test("gives up with stillProvisioning once the waits run out")
    func timesOut() async {
        let api = FakePublishing(creates: [.row(publication(state: "provisioning"))])
        await #expect(throws: CloudPortShareError.stillProvisioning) {
            _ = try await service(api, delays: [.seconds(1), .seconds(1)]).share(vmID: "brave-otter", port: 8000, teamID: nil)
        }
    }

    @Test("waits past the edge's 503 and unknown-route 404 before handing back a link")
    func waitsForEdge() async throws {
        let api = FakePublishing(creates: [.row(publication(state: "active"))])
        let statuses = Statuses([503, nil, 404, 401])
        let link = try await service(api, probe: { _ in await statuses.next() }).share(vmID: "brave-otter", port: 8000, teamID: nil)
        #expect(link.state == "active")
        #expect(await statuses.remaining == 0)
    }

    @Test("an edge that never answers is stillProvisioning, not a copied 503")
    func edgeNeverReady() async {
        let api = FakePublishing(creates: [.row(publication(state: "active"))])
        await #expect(throws: CloudPortShareError.stillProvisioning) {
            _ = try await service(api, delays: [.seconds(1)], probe: { _ in 503 }).share(vmID: "brave-otter", port: 8000, teamID: nil)
        }
    }

    @Test("a public link is never probed, since the probe would reach the user's app")
    func publicSkipsProbe() async throws {
        let api = FakePublishing(creates: [.row(publication(state: "active", access: .public))])
        let link = try await service(api, probe: { _ in Issue.record("probed a public link"); return 503 })
            .share(vmID: "brave-otter", port: 8000, teamID: nil)
        #expect(link.accessMode == .public)
    }

    private func service(
        _ api: FakePublishing,
        delays: [Duration] = [.seconds(1), .seconds(1), .seconds(1), .seconds(1)],
        probe: @escaping CloudPortShareService.Probe = { _ in 401 }
    ) -> CloudPortShareService {
        CloudPortShareService(api: api, pollDelays: delays, sleep: { _ in }, probe: probe)
    }
}

@Suite("Cloud port share store")
@MainActor
struct CloudPortShareStoreTests {
    private let key = CloudPortShareStore.Key(machineID: "brave-otter", port: 8000)

    @Test("a held phase clears itself after the hold")
    func holdClears() async {
        let gate = Gate()
        let store = CloudPortShareStore(sleep: { _ in await gate.wait() })
        store.set(.copied(.team), for: key, holdFor: .seconds(2))
        #expect(store.phase(for: key) == .copied(.team))
        await gate.open()
        await waitUntil { store.phase(for: key) == nil }
        #expect(store.phase(for: key) == nil)
    }

    @Test("a newer phase is not cleared by an older phase's hold")
    func newerPhaseSurvives() async {
        let gate = Gate()
        let store = CloudPortShareStore(sleep: { _ in await gate.wait() })
        store.set(.failed, for: key, holdFor: .seconds(4))
        store.set(.creating, for: key)
        await gate.open()
        for _ in 0..<20 { await Task.yield() }
        #expect(store.phase(for: key) == .creating)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
    }
}

private func publication(
    id: String = "pub-1",
    port: Int = 8000,
    state: String,
    access: VMPublicationAccessMode = .team,
    domainKind: String = "generated"
) -> VMPublication {
    VMPublication(
        id: id,
        hostname: "brave-otter--team--\(port).cmux.sh",
        url: "https://brave-otter--team--\(port).cmux.sh",
        domainKind: domainKind,
        vmID: "brave-otter",
        port: port,
        accessMode: access,
        teamID: access == .team ? "team-1" : nil,
        state: state,
        routingRevision: 1,
        verification: nil
    )
}

private actor Statuses {
    private var values: [Int?]
    init(_ values: [Int?]) { self.values = values }
    var remaining: Int { values.count }
    func next() -> Int? { values.isEmpty ? 401 : values.removeFirst() }
}

/// Holds sleepers until the test opens it.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private actor FakePublishing: CloudPortPublishing {
    enum Create {
        case row(VMPublication)
        case status(Int)
    }

    private(set) var calls: [String] = []
    private let listed: [VMPublication]
    private var creates: [Create]

    init(listed: [VMPublication] = [], creates: [Create] = []) {
        self.listed = listed
        self.creates = creates
    }

    func listPublications(scopeTeamID: String?) async throws -> [VMPublication] {
        calls.append("list \(scopeTeamID ?? "-")")
        return listed
    }

    /// Plays the scripted answers in order, repeating the last one.
    func createDefaultPublication(vmID: String, port: Int, scopeTeamID: String?) async throws -> VMPublication {
        calls.append("create \(vmID):\(port) \(scopeTeamID ?? "-")")
        guard let next = creates.first else { throw VMClientError.httpStatus(500, "no scripted create") }
        if creates.count > 1 { creates.removeFirst() }
        switch next {
        case .row(let publication): return publication
        case .status(let status): throw VMClientError.httpStatus(status, "{}")
        }
    }

    func deletePublication(id: String, scopeTeamID: String?) async throws {
        calls.append("delete \(id) \(scopeTeamID ?? "-")")
    }
}
