import CmuxMobileFeed
import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileLive

// MARK: A scripted Cloud service

/// Answers `LiveAPI` requests from a per-host script, so each test has its
/// own service. A held reply waits for `release(host:)` (a request already
/// on its way); nothing blocks the shared custom-protocol thread.
final class ServiceStub: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = "{}"
        var headers: [String: String] = [:]
        var held = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: @Sendable (URLRequest) -> Reply?] = [:]
    nonisolated(unsafe) private static var seen: [String: [String]] = [:]
    nonisolated(unsafe) private static var heldReplies: [String: [(ServiceStub, Thread, Reply)]] = [:]

    static func install(host: String, _ script: @escaping @Sendable (URLRequest) -> Reply?) {
        lock.withLock { scripts[host] = script }
    }

    static func requests(host: String) -> [String] {
        lock.withLock { seen[host] ?? [] }
    }

    /// Sends the replies held for `host`.
    static func release(host: String) {
        let held = lock.withLock { heldReplies.removeValue(forKey: host) ?? [] }
        for (stub, thread, reply) in held {
            stub.perform(#selector(deliverHeld), on: thread, with: ReplyBox(reply), waitUntilDone: false)
        }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServiceStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let line = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
        let script = Self.lock.withLock { () -> (@Sendable (URLRequest) -> Reply?)? in
            Self.seen[host, default: []].append(line)
            return Self.scripts[host]
        }
        // No answer: the request stays open (a service that is slow to reply).
        guard let reply = script?(request) else { return }
        if reply.held {
            Self.lock.withLock { Self.heldReplies[host, default: []].append((self, Thread.current, reply)) }
            return
        }
        deliver(reply)
    }

    private final class ReplyBox: NSObject {
        let reply: Reply
        init(_ reply: Reply) { self.reply = reply }
    }

    @objc private func deliverHeld(_ box: ReplyBox) {
        deliver(box.reply)
    }

    private func deliver(_ reply: Reply) {
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// The coordinator is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
@MainActor
@Suite struct MacRemovalTests {
    let host = "svc-\(UUID().uuidString.prefix(8).lowercased()).cmuxMobile.test"
    let userID = "user-\(UUID().uuidString)"

    func api() -> LiveAPI {
        LiveAPI(baseURL: URL(string: "https://\(host)")!, session: ServiceStub.session()) { _ in "token" }
    }

    func macsJSON(_ macs: [(String, Bool)], team: String = "t1") -> String {
        let items = macs.map { #"{"deviceId":"\#($0.0)","name":"\#($0.0)","online":\#($0.1),"teamId":"\#(team)"}"# }
        return #"{"macs":[\#(items.joined(separator: ","))]}"#
    }

    /// A coordinator restored from a snapshot of team t1 with Studio (m1,
    /// online, the linked Mac) and an old install (m2, offline), each with
    /// a cached workspace. The team load never answers, so only the test's
    /// own calls change the Mac lists.
    func coordinator(store: AppStore) throws -> LiveCoordinator {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-mobile-removal-\(UUID().uuidString)")
        let snapshots = LiveSnapshotStore(directory: directory)
        let saved = Date(timeIntervalSince1970: 1_000)
        func ws(_ id: String, _ mac: String) -> Workspace {
            Workspace(id: id, macID: mac, title: id, directory: "~", tabs: [], lastActivityAt: saved)
        }
        snapshots.save(LiveSnapshot(
            teamID: "t1", teamName: "One",
            macs: [MacDevice(id: "m1", name: "Studio", isOnline: true), MacDevice(id: "m2", name: "cmux NEXT mobile", isOnline: false)],
            linkedMacID: "m1",
            workspaces: ["m1": .init(workspaces: [ws("w1", "m1")], savedAt: saved), "m2": .init(workspaces: [ws("w2", "m2")], savedAt: saved)]
        ), accountID: userID)
        snapshots.flush()
        return LiveCoordinator(
            store: store, api: api(), identity: DeviceIdentity(link: UUID().uuidString, presence: UUID().uuidString),
            userID: userID, deviceName: "iPhone", transport: .wireGuard, dialer: MockDialer(fail: false),
            feedStore: FeedStore(items: []), snapshots: snapshots
        )
    }

    func emptyStore() -> AppStore {
        AppStore(teams: [], activeTeamID: "", workspaces: [], feed: [], tabMemory: .inMemory())
    }

    /// Waits (at most 3 s) for the link, its dialer and the observation hops to land.
    func settle(_ done: () -> Bool) async {
        for _ in 0..<3000 where !done() { try? await Task.sleep(for: .milliseconds(1)) }
    }

    /// Lets every pending hop run, for checks that nothing comes back.
    func drain() async {
        for _ in 0..<50 { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func removingTheLinkedMacDisconnectsCleanlyAndPurgesIt() async throws {
        ServiceStub.install(host: host) { request in
            request.httpMethod == "DELETE" ? .init(body: #"{"deleted":true,"deviceId":"m1"}"#) : nil
        }
        let store = emptyStore()
        let live = try coordinator(store: store)
        defer { live.stop() }
        var removedIDs: [String] = []
        live.onMacRemoved = { removedIDs.append($0) }
        await settle { store.macConnection["m1"] == .connected }
        #expect(live.link.target?.macID == "m1")
        #expect(store.macConnection["m1"] == .connected)

        try await live.removeDevice(id: "m1")
        await settle { live.link.target?.macID == "m2" && live.link.phase == .macOffline }

        #expect(ServiceStub.requests(host: host).contains("DELETE /v1/devices/m1"))
        #expect(store.teams.flatMap(\.macs).map(\.id) == ["m2"])
        #expect(store.workspaces.map(\.id) == ["w2"])
        #expect(removedIDs == ["m1"])
        // The link left it: on to the other Mac, which is offline, not dialing a Mac that is gone.
        #expect(live.link.target?.macID == "m2")
        #expect(live.link.phase == .macOffline)
        // Nothing about m1 comes back once the link's phase change lands.
        await drain()
        #expect(store.macConnection["m1"] == nil)
        #expect(store.macData["m1"] == nil)
        #expect(store.macLinkStatus["m1"] == nil)
        #expect(live.banner?.text.contains("Studio") != true)
    }

    @Test func removingTheOnlyMacLeavesTheLinkIdle() async throws {
        ServiceStub.install(host: host) { request in
            request.httpMethod == "DELETE" ? .init(body: "{}") : nil
        }
        let store = emptyStore()
        let live = try coordinator(store: store)
        defer { live.stop() }
        await settle { live.link.phase.isConnected }
        try await live.removeDevice(id: "m2")
        try await live.removeDevice(id: "m1")
        await settle { live.link.phase == .idle }
        #expect(live.link.target == nil)
        #expect(live.link.phase == .idle)
        #expect(store.activeTeam?.macs.isEmpty == true)
        #expect(store.workspaces.isEmpty)
        await drain()
        #expect(live.banner == nil)
        #expect(store.macLinkStatus.isEmpty)
    }

    @Test func anAnswerAlreadyOnItsWayDoesNotBringTheMacBack() async throws {
        let body = macsJSON([("m1", true), ("m2", false)])
        let held = Counter()
        ServiceStub.install(host: host) { request in
            switch (request.httpMethod, request.url?.path()) {
            case ("DELETE", _): .init(body: "{}")
            // Only the first discovery is held.
            case ("GET", "/v1/me/macs"): .init(body: body, held: held.increment() == 1)
            default: nil
            }
        }
        let store = emptyStore()
        let live = try coordinator(store: store)
        defer { live.stop() }
        // Discovery asks, and its reply is held until after the removal.
        let discovery = Task { await live.discoverOnce() }
        for _ in 0..<200 where !ServiceStub.requests(host: host).contains("GET /v1/me/macs") {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await live.removeDevice(id: "m2")
        ServiceStub.release(host: host)
        await discovery.value
        #expect(store.teams.flatMap(\.macs).map(\.id) == ["m1"])
        // Asked after the removal, the same answer is the truth (it signed in again).
        await live.discoverOnce()
        #expect(store.teams.flatMap(\.macs).map(\.id).sorted() == ["m1", "m2"])
    }

    @Test func aMacRemovedElsewhereLeavesWithTheNextDiscovery() async throws {
        let both = macsJSON([("m1", true), ("m2", false)])
        let one = macsJSON([("m1", true)])
        let calls = Counter()
        ServiceStub.install(host: host) { request in
            guard request.url?.path() == "/v1/me/macs" else { return nil }
            return .init(body: calls.increment() == 1 ? both : one)
        }
        let store = emptyStore()
        let live = try coordinator(store: store)
        defer { live.stop() }
        await live.discoverOnce()
        #expect(store.workspaces.contains { $0.macID == "m2" })
        await live.discoverOnce()
        #expect(store.teams.flatMap(\.macs).map(\.id) == ["m1"])
        #expect(!store.workspaces.contains { $0.macID == "m2" })
    }

    @Test func alreadyRemovedCountsAsRemoved() async throws {
        ServiceStub.install(host: host) { request in
            request.httpMethod == "DELETE" ? .init(status: 404, body: #"{"error":{"code":"not_found","message":"no such device"}}"#) : nil
        }
        let store = emptyStore()
        let live = try coordinator(store: store)
        defer { live.stop() }
        try await live.removeDevice(id: "m2")
        #expect(store.teams.flatMap(\.macs).map(\.id) == ["m1"])
    }

    @Test func aRefusalKeepsTheMacAndCarriesTheRequestID() async throws {
        ServiceStub.install(host: host) { request in
            request.httpMethod == "DELETE"
                ? .init(status: 403, body: #"{"error":{"code":"not_owner","message":"this device belongs to another user"}}"#,
                        headers: ["CF-Ray": "8c1f2a3b4c5d6e7f-SJC"])
                : nil
        }
        let store = emptyStore()
        let live = try coordinator(store: store)
        defer { live.stop() }
        await #expect(throws: LiveAPI.Failure(status: 403, code: "not_owner", message: "this device belongs to another user", requestID: "8c1f2a3b4c5d6e7f-SJC")) {
            try await live.removeDevice(id: "m2")
        }
        #expect(store.teams.flatMap(\.macs).map(\.id) == ["m1", "m2"])
        #expect(store.workspaces.contains { $0.macID == "m2" })
    }
}

#endif

@Suite struct RemovalMessageTests {
    @Test func explainsRefusalsWithTheRequestID() {
        let notOwner = LiveAPI.removalMessage(for: LiveAPI.Failure(status: 403, code: "not_owner", message: "x", requestID: "r1"))
        #expect(notOwner.text.contains("another account"))
        #expect(notOwner.display.hasSuffix("Request ID: r1"))
        let server = LiveAPI.removalMessage(for: LiveAPI.Failure(status: 503, code: "http_503", message: "", requestID: nil))
        #expect(server.text == "The Cloud service couldn't remove it (http_503). Try again in a moment.")
        #expect(server.requestID == nil)
    }

    @Test func offlineSaysSo() {
        #expect(LiveAPI.removalMessage(for: URLError(.notConnectedToInternet)).text == "You're offline. Connect to the internet and try again.")
    }

    @Test func requestIDPrefersTheServiceHeader() {
        let url = URL(string: "https://x")!
        let both = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: ["X-Request-Id": "a", "CF-Ray": "b"])
        let edge = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: ["CF-Ray": "b"])
        let none = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: [:])
        #expect(LiveAPI.requestID(both) == "a")
        #expect(LiveAPI.requestID(edge) == "b")
        #expect(LiveAPI.requestID(none) == nil)
    }
}
