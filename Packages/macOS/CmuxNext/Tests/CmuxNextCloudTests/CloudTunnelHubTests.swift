@testable import CmuxNextCloud
import Foundation
import Synchronization
import Testing

/// Serves `/api/vm` calls. The first POST is held until the test releases
/// it (answered with `heldStatus`/`heldBody`); every other request fails
/// at once with 500.
final class TunnelStubProtocol: URLProtocol, @unchecked Sendable {
    struct Log {
        var entries: [String] = []
        var held: TunnelStubProtocol?
        var posts = 0
        var heldStatus = 500
        var heldBody = "{}"
    }

    static let log = Mutex(Log())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let hold = Self.log.withLock { log -> Bool in
            log.entries.append("\(method) \(request.url?.path ?? "") received")
            guard method == "POST" else { return false }
            log.posts += 1
            guard log.posts == 1 else { return false }
            log.held = self
            return true
        }
        if !hold { respond(status: 500, body: "{}") }
    }

    override func stopLoading() {}

    func respond(status: Int, body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func releaseHeld() {
        guard let (held, status, body) = log.withLock({ log -> (TunnelStubProtocol, Int, String)? in
            defer { log.held = nil }
            log.entries.append("POST completed")
            return log.held.map { ($0, log.heldStatus, log.heldBody) }
        }) else { return }
        held.respond(status: status, body: body)
    }

    /// Clears the log; the next POST is held and answered with `status`/`body`.
    static func reset(status: Int = 500, body: String = "{}") {
        log.withLock { $0 = Log(heldStatus: status, heldBody: body) }
    }

    static func waitForFirstPost() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while log.withLock({ $0.held == nil }) {
            guard ContinuousClock.now < deadline else { throw CloudAPIError.timedOut("first POST") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static var entries: [String] { log.withLock { $0.entries } }
    static var posts: Int { log.withLock { $0.posts } }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct CloudTunnelHubTests {
    private static func parts() -> (CloudAPIClient, CloudPaths) {
        let configuration = CloudConfiguration.resolve(bundleID: "test.hub", bundled: ["CMUX_VM_API_BASE_URL": "https://hub.test"],
                                                       process: [:], isDebugBuild: true)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [TunnelStubProtocol.self]
        let api = CloudAPIClient(configuration: configuration, tokens: { ("a", "r") }, teamID: { nil },
                                 session: URLSession(configuration: sessionConfiguration))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hub-\(UUID().uuidString)")
        return (api, CloudPaths(root: root))
    }

    private static func hub() -> CloudTunnelHub {
        let (api, paths) = parts()
        return CloudTunnelHub(api: api, paths: paths, binary: URL(fileURLWithPath: "/bin/echo"), deviceName: "cmux-test")
    }

    /// Regression: sign-out revoked this Mac's WireGuard peer while an
    /// enrollment (started by a machine link) was still in flight. The
    /// revoke could reach the server first, the enrollment then re-created
    /// the peer, and later link starts enrolled again while signed out.
    @Test func revokeWaitsForAnInFlightEnrollmentAndBlocksNewOnes() async throws {
        TunnelStubProtocol.reset()
        let hub = Self.hub()
        let start = Task { try await hub.socketPath() }
        try await TunnelStubProtocol.waitForFirstPost()
        let revoke = Task { await hub.revoke() }
        try await Task.sleep(for: .milliseconds(100)) // give an eager revoke time to go out; test-only
        TunnelStubProtocol.releaseHeld()
        await revoke.value
        _ = await start.result
        #expect(TunnelStubProtocol.entries == ["POST /api/vm/tunnel received", "POST completed", "DELETE /api/vm/tunnel received"])

        await #expect(throws: (any Error).self) { try await hub.socketPath() }
        #expect(TunnelStubProtocol.posts == 1)
    }

    /// Regression: a machine link stopped (machine removed, sign-out) while
    /// it waited for its attach endpoint still went on to start the hub
    /// (enrolling this Mac's WireGuard peer) and spawn `remote connect`.
    @Test func linkStoppedDuringStartDoesNotReachTheHub() async throws {
        TunnelStubProtocol.reset(status: 200, body: #"{"transport":"cmux-remote","route":"ws://10.0.0.2:1337/v1/link","session":"s","trustedCarrier":true}"#)
        let (api, paths) = Self.parts()
        let hub = CloudTunnelHub(api: api, paths: paths, binary: URL(fileURLWithPath: "/bin/echo"), deviceName: "cmux-test")
        let link = CloudMachineLink(machineID: "vm-1", api: api, hub: hub, paths: paths, binary: URL(fileURLWithPath: "/bin/echo"),
                                    deviceName: "cmux-test")
        let start = Task { try await link.socketPath() }
        try await TunnelStubProtocol.waitForFirstPost()
        await link.stop()
        TunnelStubProtocol.releaseHeld()
        await #expect(throws: (any Error).self) { try await start.value }
        #expect(TunnelStubProtocol.posts == 1)
        #expect(await link.pid == nil)
    }
}
