@testable import CmuxNextCloud
import Foundation
import Synchronization
import Testing

final class LifecycleStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = "{}"
    }

    static let seen = Mutex<[URLRequest]>([])
    static let reply = Mutex(Reply())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.withLock { $0.append(request) }
        let reply = Self.reply.withLock { $0 }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct CloudLifecycleTests {
    private static func api() -> CloudAPIClient {
        let configuration = CloudConfiguration.resolve(bundleID: "test.lifecycle", bundled: ["CMUX_VM_API_BASE_URL": "https://lifecycle.test"],
                                                       process: [:], isDebugBuild: true)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [LifecycleStubProtocol.self]
        return CloudAPIClient(configuration: configuration, tokens: { ("access", "refresh") }, teamID: { "team-1" },
                              session: URLSession(configuration: sessionConfiguration))
    }

    @Test(arguments: ["pause", "resume", "delete-snapshot"])
    func lifecycleUsesTheAuthenticatedMachineRoute(operation: String) async throws {
        LifecycleStubProtocol.seen.withLock { $0 = [] }
        LifecycleStubProtocol.reply.withLock { $0 = .init() }
        let api = Self.api()
        let method: String, path: String, timeout: TimeInterval
        switch operation {
        case "pause":
            try await api.pauseMachine("vm-1")
            (method, path, timeout) = ("POST", "/api/vm/vm-1/pause", 960)
        case "resume":
            try await api.resumeMachine("vm-1")
            (method, path, timeout) = ("POST", "/api/vm/vm-1/resume", 960)
        default:
            try await api.deleteSnapshot("vm-1", snapshotID: "snap-2")
            (method, path, timeout) = ("DELETE", "/api/vm/vm-1/snapshots/snap-2", 960)
        }
        let requests = LifecycleStubProtocol.seen.withLock { $0 }
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.httpMethod == method)
        #expect(request.url?.path == path)
        #expect(request.timeoutInterval == timeout)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        #expect(request.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh")
        #expect(request.value(forHTTPHeaderField: "X-Cmux-Team-Id") == "team-1")
        #expect(request.httpBody == nil)
    }

    @Test func snapshotDeletionPreservesOwnershipFailure() async throws {
        LifecycleStubProtocol.reply.withLock {
            $0 = .init(status: 404, body: #"{"error":"vm_snapshot_not_found","message":"Snapshot not found"}"#)
        }
        await #expect(throws: CloudAPIError.http(status: 404, code: "vm_snapshot_not_found", message: "Snapshot not found")) {
            try await Self.api().deleteSnapshot("vm-1", snapshotID: "snap-other-machine")
        }
    }

    @Test func resumePreservesPlanFailure() async throws {
        LifecycleStubProtocol.reply.withLock {
            $0 = .init(status: 402, body: #"{"error":"vm_requires_pro","message":"Upgrade to resume"}"#)
        }
        await #expect(throws: CloudAPIError.http(status: 402, code: "vm_requires_pro", message: "Upgrade to resume")) {
            try await Self.api().resumeMachine("vm-1")
        }
    }
}
