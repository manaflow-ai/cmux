import CmuxCloud
import Foundation
import Testing

@Suite("Cloud port share service")
struct CloudPortShareServiceTests {
    enum CancellationPoint: CaseIterable, Sendable {
        case beforeStart, list, create, probe, retryDelay
    }

    @Test("cancellation stops sharing even when a dependency finishes normally", arguments: CancellationPoint.allCases)
    func cancellationStopsSharing(at point: CancellationPoint) async {
        let entered = Gate()
        let release = Gate()
        let pause: @Sendable () async -> Void = {
            await entered.open()
            await release.wait()
        }
        let api = FakePublishing(
            creates: [.row(publication(state: point == .retryDelay ? "provisioning" : "active"))],
            beforeListReturn: { if point == .list { await pause() } },
            beforeCreateReturn: { if point == .create { await pause() } }
        )
        let service = CloudPortShareService(
            api: api,
            pollDelays: [.seconds(1)],
            sleep: { _ in if point == .retryDelay { await pause() } },
            probe: { _ in
                if point == .probe { await pause() }
                return 401
            }
        )
        let task = Task {
            if point == .beforeStart { await pause() }
            return try await service.share(vmID: "brave-otter", port: 8000, teamID: "team-1")
        }
        await entered.wait()
        task.cancel()
        await release.open()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let expectedCalls: [String] = point == .beforeStart ? [] : point == .list
            ? ["list team-1"] : ["list team-1", "create brave-otter:8000 team-1"]
        #expect(await api.calls == expectedCalls)
    }

    @Test("the signed-out readiness request uses a safe HTTP method")
    func readinessRequestIsSafe() async throws {
        try #require(URLProtocol.registerClass(PortShareProbeProtocol.self))
        defer { URLProtocol.unregisterClass(PortShareProbeProtocol.self) }
        let url = try #require(URL(string: "https://port-share-probe-test.invalid/"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PortShareProbeProtocol.self]
        let status = await CloudPortShareService.signedOutStatus(url, configuration: configuration)
        #expect(status == 200)
        let request = try #require(PortShareProbeProtocol.capturedRequest())
        #expect(request.httpMethod == "HEAD")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

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

    @Test("a public link waits for the edge before copying")
    func publicWaitsForEdge() async throws {
        let api = FakePublishing(creates: [.row(publication(state: "active", access: .public))])
        let statuses = Statuses([503, 200])
        let link = try await service(api, probe: { _ in await statuses.next() })
            .share(vmID: "brave-otter", port: 8000, teamID: nil)
        #expect(link.accessMode == .public)
        #expect(await statuses.remaining == 0)
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

    @Test("a cancelled operation cannot clear its replacement")
    func cancelledOperationDoesNotClearReplacement() throws {
        let store = CloudPortShareStore()
        let first = #require(store.beginCreating(key))
        store.clear(key, operationID: first)
        let replacement = #require(store.beginCreating(key))
        store.clear(key, operationID: first)
        #expect(store.phase(for: key) == .creating)
        store.clear(key, operationID: replacement)
        #expect(store.phase(for: key) == nil)
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
    private let beforeListReturn: @Sendable () async -> Void
    private let beforeCreateReturn: @Sendable () async -> Void

    init(
        listed: [VMPublication] = [], creates: [Create] = [],
        beforeListReturn: @escaping @Sendable () async -> Void = {},
        beforeCreateReturn: @escaping @Sendable () async -> Void = {}
    ) {
        self.listed = listed
        self.creates = creates
        self.beforeListReturn = beforeListReturn
        self.beforeCreateReturn = beforeCreateReturn
    }

    func listPublications(scopeTeamID: String?) async throws -> [VMPublication] {
        calls.append("list \(scopeTeamID ?? "-")")
        await beforeListReturn()
        return listed
    }

    /// Plays the scripted answers in order, repeating the last one.
    func createDefaultPublication(vmID: String, port: Int, scopeTeamID: String?) async throws -> VMPublication {
        calls.append("create \(vmID):\(port) \(scopeTeamID ?? "-")")
        await beforeCreateReturn()
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

/// Intercepts only this test's hostname; other URLSession traffic is unaffected.
private final class PortShareProbeProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: URLRequest?

    static func capturedRequest() -> URLRequest? { lock.withLock { captured } }
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "port-share-probe-test.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.captured = request }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
