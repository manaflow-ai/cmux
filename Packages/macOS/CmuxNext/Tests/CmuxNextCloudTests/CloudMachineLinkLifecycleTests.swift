@testable import CmuxNextCloud
import Foundation
import Synchronization
import Testing

/// Holds the first machine attach response so a lifecycle transition can race
/// an in-flight link start without contacting a provider or spawning a real
/// cmux-tui process.
final class LinkLifecycleStubProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var paths: [String] = []
        var attachCount = 0
        var heldAttach: LinkLifecycleStubProtocol?
    }

    static let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let hold = Self.state.withLock { state -> Bool in
            state.paths.append(path)
            guard path == "/api/vm/vm-1/attach-endpoint" else { return false }
            state.attachCount += 1
            guard state.attachCount == 1 else { return false }
            state.heldAttach = self
            return true
        }
        if !hold {
            if path == "/api/vm/vm-1/attach-endpoint" {
                respond(status: 200, body: #"{"transport":"cmux-remote","route":"ws://10.0.0.2:1337/v1/link","session":"s","trustedCarrier":true}"#)
            } else {
                respond(status: 500, body: "{}")
            }
        }
    }

    override func stopLoading() {}

    func respond(status: Int, body: String) {
        guard let url = request.url,
              let client else { return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data(body.utf8))
        client.urlProtocolDidFinishLoading(self)
    }

    static func reset() { state.withLock { $0 = State() } }

    static func releaseAttach() {
        let held = state.withLock { state -> LinkLifecycleStubProtocol? in
            defer { state.heldAttach = nil }
            return state.heldAttach
        }
        held?.respond(status: 200, body: #"{"transport":"cmux-remote","route":"ws://10.0.0.2:1337/v1/link","session":"s","trustedCarrier":true}"#)
    }

    static func waitForAttach() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while state.withLock({ $0.heldAttach == nil }) {
            guard ContinuousClock.now < deadline else { throw CloudAPIError.timedOut("attach endpoint") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct CloudMachineLinkLifecycleTests {
    private static func link() -> CloudMachineLink {
        let configuration = CloudConfiguration.resolve(bundleID: "test.link-lifecycle",
                                                       bundled: ["CMUX_VM_API_BASE_URL": "https://link-lifecycle.test"],
                                                       process: [:], isDebugBuild: true)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [LinkLifecycleStubProtocol.self]
        let api = CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { nil },
                                 session: URLSession(configuration: sessionConfiguration))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("link-lifecycle-\(UUID().uuidString)")
        let paths = CloudPaths(root: root)
        let hub = CloudTunnelHub(api: api, paths: paths, binary: URL(fileURLWithPath: "/bin/echo"), deviceName: "cmux-test")
        return CloudMachineLink(machineID: "vm-1", api: api, hub: hub, paths: paths,
                                binary: URL(fileURLWithPath: "/bin/echo"), deviceName: "cmux-test")
    }

    /// A pause while attach is waiting must cancel that start before it can
    /// enroll the tunnel. After resume, the same session must make a fresh
    /// attach attempt rather than awaiting the stale task.
    @Test func suspendDuringAttachCancelsStaleStartAndResumeRetries() async throws {
        LinkLifecycleStubProtocol.reset()
        let link = Self.link()
        let first = Task { try await link.socketPath() }
        try await LinkLifecycleStubProtocol.waitForAttach()

        await link.suspend()
        LinkLifecycleStubProtocol.releaseAttach()
        await #expect(throws: (any Error).self) { try await first.value }
        #expect(await link.pid == nil)
        #expect(LinkLifecycleStubProtocol.state.withLock { $0.paths } == ["/api/vm/vm-1/attach-endpoint"])
        await #expect(throws: (any Error).self) { try await link.socketPath() }
        #expect(LinkLifecycleStubProtocol.state.withLock { $0.paths } == ["/api/vm/vm-1/attach-endpoint"])

        await link.resume()
        await #expect(throws: (any Error).self) { try await link.socketPath() }
        let (attachCount, paths) = LinkLifecycleStubProtocol.state.withLock { ($0.attachCount, $0.paths) }
        #expect(attachCount == 2)
        #expect(paths.filter { $0 == "/api/vm/vm-1/attach-endpoint" }.count == 2)
    }
}
