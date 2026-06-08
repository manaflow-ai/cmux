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
        let captured = RecordedRequest(
            host: request.url?.host ?? "",
            method: request.httpMethod ?? "?",
            path: request.url?.path ?? "",
            body: bodyData
        )
        Task { await RecordingURLProtocol.recorder.record(captured) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
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
    func reset() { requests = [] }

    /// HTTP methods recorded for `host`, in order.
    func methods(host: String) -> [String] {
        requests.filter { $0.host == host }.map(\.method)
    }

    /// Whether any request was recorded for `host`.
    func hasRequests(host: String) -> Bool {
        requests.contains { $0.host == host }
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
        // No tokens → upload is skipped, but the local choice must persist so the
        // next sign-in re-uploads it.
        let (service, _, host) = makeService(tokenProvider: FakeTokenProvider(access: nil, refresh: nil))
        await service.setWorkspaceMuted("ws-a", muted: true)
        #expect(await service.mutedWorkspaceIDs == ["ws-a"])
        #expect(await RecordingURLProtocol.recorder.hasRequests(host: host) == false)
    }
}
