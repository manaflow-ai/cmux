import Foundation
import Testing
@testable import CmuxAuthRuntime

/// Records every URLRequest the push service performs, returning 200.
final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    // Mutations are serialized by the URL loading system; a lock-free actor
    // box keeps captured requests for assertions.
    nonisolated(unsafe) static let recorder = RequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLProtocol nils out `httpBody` when the loading system converts it to
        // a stream, so read the stream to capture the JSON body for assertions.
        let bodyData = Self.bodyData(from: request)
        let host = request.url?.host ?? ""
        let method = request.httpMethod ?? "?"
        let captured = RecordedRequest(
            host: host,
            method: method,
            path: request.url?.path ?? "",
            body: bodyData
        )
        // Snapshot the canned GET response synchronously so the response is ready
        // before this loader finishes (the recorder actor read is deferred).
        let cannedResponse = Self.responseStore.response(for: host)
        Task { await RecordingURLProtocol.recorder.record(captured) }
        let status = (method == "GET") ? (cannedResponse?.status ?? 200) : 200
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if method == "GET", let body = cannedResponse?.body {
            client?.urlProtocol(self, didLoad: body)
        } else {
            client?.urlProtocol(self, didLoad: Data())
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Per-host canned GET responses, keyed by the test's unique API host.
    /// `startLoading()` is synchronous and cannot await the recorder actor, so a
    /// lock-guarded store provides real synchronization for parallel test writes
    /// + protocol reads (distinct keys alone do NOT make a `Dictionary` thread
    /// safe).
    static let responseStore = CannedResponseStore()

    struct CannedResponse: Sendable {
        var status: Int = 200
        var body: Data?
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Thread-safe canned-response store for ``RecordingURLProtocol``.
final class CannedResponseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String: RecordingURLProtocol.CannedResponse] = [:]

    func set(_ response: RecordingURLProtocol.CannedResponse, for host: String) {
        lock.lock()
        defer { lock.unlock() }
        responses[host] = response
    }

    func response(for host: String) -> RecordingURLProtocol.CannedResponse? {
        lock.lock()
        defer { lock.unlock() }
        return responses[host]
    }
}

struct RecordedRequest: Sendable {
    let host: String
    let method: String
    let path: String
    let body: Data?
}

/// The recorder is process-global because `URLProtocol` has no per-session hook,
/// and Swift Testing runs cases in parallel, so every assertion is scoped to the
/// calling test's unique API host (`makeService` assigns one per test). Without
/// host scoping, a concurrent test's PUT would clobber another's "last" request.
actor RequestRecorder {
    private(set) var requests: [RecordedRequest] = []
    func record(_ request: RecordedRequest) { requests.append(request) }

    /// HTTP methods recorded for `host`, in order.
    func methods(host: String) -> [String] {
        requests.filter { $0.host == host }.map(\.method)
    }

    /// Whether any request was recorded for `host`.
    func hasRequests(host: String) -> Bool {
        requests.contains { $0.host == host }
    }

    /// Number of requests recorded for `host`.
    func count(host: String) -> Int {
        requests.filter { $0.host == host }.count
    }

    /// The decoded `workspaceIds` array from the most recent mute-sync PUT for
    /// `host`, or `nil` if no such request was recorded.
    func lastMutedWorkspaceIDs(host: String) -> [String]? {
        guard let request = requests.last(where: {
            $0.host == host && $0.method == "PUT" && $0.path.hasSuffix("/api/notifications/mutes")
        }),
              let body = request.body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let ids = object["workspaceIds"] as? [String]
        else { return nil }
        return ids
    }
}

struct FakeTokenProvider: TokenProviding {
    var access: String? = "access"
    var refresh: String? = "refresh"
    func accessToken() async throws -> String {
        guard let access else { throw AuthError.unauthorized }
        return access
    }
    func refreshToken() async -> String? { refresh }
    func forceRefreshAccessToken() async throws -> String {
        guard let access else { throw AuthError.unauthorized }
        return access
    }
}

@Suite struct PushRegistrationServiceTests {
    /// A unique API host per test so the process-global recorder can scope its
    /// assertions to the calling test under parallel execution.
    private func makeService(
        tokenProvider: any TokenProviding = FakeTokenProvider()
    ) -> (PushRegistrationService, UserDefaults, String) {
        let suite = "push-test-\(UUID().uuidString)"
        let host = "t-\(UUID().uuidString).example.test"
        let defaults = UserDefaults(suiteName: suite)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let service = PushRegistrationService(
            tokenProvider: tokenProvider,
            apiBaseURL: "https://\(host)",
            bundleID: "dev.cmux.ios",
            apnsEnvironment: "sandbox",
            suiteName: suite,
            session: URLSession(configuration: configuration)
        )
        return (service, defaults, host)
    }

    @Test func disabledByDefault() async {
        let (service, _, _) = makeService()
        #expect(await service.isEnabled == false)
    }

    @Test func registeringWhileDisabledCachesButDoesNotUpload() async {
        let (service, _, host) = makeService()
        await service.register(deviceToken: Data([0xAB, 0xCD]))
        // No upload because notifications are off.
        #expect(await RecordingURLProtocol.recorder.methods(host: host).isEmpty)
    }

    @Test func enablingUploadsCachedToken() async {
        let (service, defaults, host) = makeService()
        await service.register(deviceToken: Data([0xAB, 0xCD]))
        await service.setEnabled(true)
        #expect(defaults.bool(forKey: "cmux.notifications.pushEnabled"))
        #expect(await RecordingURLProtocol.recorder.methods(host: host).contains("POST"))
    }

    @Test func disablingDeletesServerToken() async {
        let (service, _, host) = makeService()
        await service.register(deviceToken: Data([0xAB, 0xCD]))
        await service.setEnabled(true)
        await service.setEnabled(false)
        #expect(await RecordingURLProtocol.recorder.methods(host: host).contains("DELETE"))
    }

    // MARK: - Per-workspace mute

    @Test func mutedWorkspacesEmptyByDefault() async {
        let (service, _, _) = makeService()
        #expect(await service.mutedWorkspaceIDs.isEmpty)
    }

    @Test func mutingPersistsAndUploadsFullSet() async {
        let (service, _, host) = makeService()
        await service.setWorkspaceMuted("ws-a", muted: true)
        #expect(await service.mutedWorkspaceIDs == ["ws-a"])
        // The mute sync is a full-set idempotent replace via PUT.
        #expect(await RecordingURLProtocol.recorder.lastMutedWorkspaceIDs(host: host) == ["ws-a"])

        await service.setWorkspaceMuted("ws-b", muted: true)
        #expect(await service.mutedWorkspaceIDs == ["ws-a", "ws-b"])
        // Sorted full set, not a per-workspace delta.
        #expect(await RecordingURLProtocol.recorder.lastMutedWorkspaceIDs(host: host) == ["ws-a", "ws-b"])
    }

    @Test func unmutingRemovesFromSetAndReuploads() async {
        let (service, _, host) = makeService()
        await service.setWorkspaceMuted("ws-a", muted: true)
        await service.setWorkspaceMuted("ws-b", muted: true)
        await service.setWorkspaceMuted("ws-a", muted: false)
        #expect(await service.mutedWorkspaceIDs == ["ws-b"])
        #expect(await RecordingURLProtocol.recorder.lastMutedWorkspaceIDs(host: host) == ["ws-b"])
    }

    @Test func mutedSetSurvivesAcrossServiceInstances() async {
        let suite = "push-mute-\(UUID().uuidString)"
        let host = "t-\(UUID().uuidString).example.test"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        func makeOne() -> PushRegistrationService {
            PushRegistrationService(
                tokenProvider: FakeTokenProvider(),
                apiBaseURL: "https://\(host)",
                bundleID: "dev.cmux.ios",
                apnsEnvironment: "sandbox",
                suiteName: suite,
                session: URLSession(configuration: configuration)
            )
        }
        await makeOne().setWorkspaceMuted("ws-persist", muted: true)
        // A fresh instance over the same suite reads the persisted set.
        #expect(await makeOne().mutedWorkspaceIDs == ["ws-persist"])
    }

    @Test func mutingWithoutAuthStillPersistsLocally() async {
        // No tokens → upload is skipped, but the local choice must persist.
        let (service, _, host) = makeService(tokenProvider: FakeTokenProvider(access: nil, refresh: nil))
        await service.setWorkspaceMuted("ws-a", muted: true)
        #expect(await service.mutedWorkspaceIDs == ["ws-a"])
        #expect(await RecordingURLProtocol.recorder.hasRequests(host: host) == false)
    }

    @Test func rapidTogglesCoalesceToASingleConvergedUpload() async {
        let (service, _, host) = makeService()
        // Fire many toggles back-to-back. With coalescing, the final server
        // upload must reflect the final local set, not an intermediate one.
        async let a: Void = service.setWorkspaceMuted("ws-a", muted: true)
        async let b: Void = service.setWorkspaceMuted("ws-b", muted: true)
        async let c: Void = service.setWorkspaceMuted("ws-a", muted: false)
        async let d: Void = service.setWorkspaceMuted("ws-c", muted: true)
        _ = await (a, b, c, d)
        let finalLocal = await service.mutedWorkspaceIDs
        // The last PUT the server sees must equal the final local set.
        #expect(await RecordingURLProtocol.recorder.lastMutedWorkspaceIDs(host: host) == finalLocal.sorted())
    }

    // MARK: - Sign-in hydration / sign-out clear (per-user scoping)

    @Test func hydrateReplacesLocalWithServerSet() async {
        let (service, _, host) = makeService()
        // A previous account left "ws-stale" cached locally.
        await service.setWorkspaceMuted("ws-stale", muted: true)
        #expect(await service.mutedWorkspaceIDs == ["ws-stale"])

        // The signed-in user's server set is ["ws-server-1", "ws-server-2"].
        RecordingURLProtocol.responseStore.set(
            .init(body: try? JSONSerialization.data(withJSONObject: ["workspaceIds": ["ws-server-1", "ws-server-2"]])),
            for: host
        )
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        // Local is replaced wholesale by the server set; the stale id is gone.
        #expect(hydrated == ["ws-server-1", "ws-server-2"])
        #expect(await service.mutedWorkspaceIDs == ["ws-server-1", "ws-server-2"])
    }

    @Test func hydrateDoesNotClobberAConcurrentLocalMutation() async {
        let (service, _, host) = makeService()
        // Server set differs from what the user is about to tap.
        RecordingURLProtocol.responseStore.set(
            .init(body: try? JSONSerialization.data(withJSONObject: ["workspaceIds": ["ws-server"]])),
            for: host
        )
        // Deterministically interleave a local mutation into the hydration's
        // reentrancy window (after the GET resolves, before the generation
        // re-check) via the test seam. The local change is newer, so hydration
        // must keep local and NOT overwrite it with the stale server set.
        await service.setAfterHydrationFetchForTesting { [service] in
            await service.setWorkspaceMuted("ws-just-tapped", muted: true)
        }
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        // The just-tapped local change is never lost.
        #expect(await service.mutedWorkspaceIDs.contains("ws-just-tapped"))
        #expect(hydrated.contains("ws-just-tapped"))
        // And the stale server-only id did not replace it.
        #expect(!(await service.mutedWorkspaceIDs).contains("ws-server"))
    }

    @Test func hydrateKeepsLocalWhenServerUnreachable() async {
        // No tokens → the GET is never made; the local set must survive so an
        // offline sign-in does not wipe valid local state.
        let (service, _, _) = makeService(tokenProvider: FakeTokenProvider(access: nil, refresh: nil))
        await service.setWorkspaceMuted("ws-local", muted: true)
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        #expect(hydrated == ["ws-local"])
        #expect(await service.mutedWorkspaceIDs == ["ws-local"])
    }

    @Test func hydrateKeepsLocalOnServerError() async {
        let (service, _, host) = makeService()
        await service.setWorkspaceMuted("ws-local", muted: true)
        // Server returns 500 → keep local rather than clobber to empty.
        RecordingURLProtocol.responseStore.set(.init(status: 500, body: nil), for: host)
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        #expect(hydrated == ["ws-local"])
        #expect(await service.mutedWorkspaceIDs == ["ws-local"])
    }

    @Test func hydrateToEmptyServerSetClearsLocal() async {
        let (service, _, host) = makeService()
        await service.setWorkspaceMuted("ws-stale", muted: true)
        // The signed-in user has no server mutes → local should end up empty.
        RecordingURLProtocol.responseStore.set(
            .init(body: try? JSONSerialization.data(withJSONObject: ["workspaceIds": [String]()])),
            for: host
        )
        let hydrated = await service.hydrateMutedWorkspacesFromServer()
        #expect(hydrated.isEmpty)
        #expect(await service.mutedWorkspaceIDs.isEmpty)
    }

    @Test func clearLocalRemovesCachedSetWithoutServerCall() async {
        let (service, _, host) = makeService()
        await service.setWorkspaceMuted("ws-a", muted: true)
        let beforeClear = await RecordingURLProtocol.recorder.count(host: host)
        await service.clearLocalMutedWorkspaces()
        #expect(await service.mutedWorkspaceIDs.isEmpty)
        // Sign-out clear is local-only: it must issue no new PUT/DELETE for the
        // server set (request count for this host is unchanged by the clear).
        #expect(await RecordingURLProtocol.recorder.count(host: host) == beforeClear)
    }
}
