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
    let method: String
    let path: String
    let body: Data?
}

actor RequestRecorder {
    private(set) var requests: [RecordedRequest] = []
    var methods: [String] { requests.map(\.method) }
    func record(_ request: RecordedRequest) { requests.append(request) }
    func reset() { requests = [] }

    /// The decoded `workspaceIds` array from the most recent mute-sync PUT, or
    /// `nil` if no such request was recorded.
    func lastMutedWorkspaceIDs() -> [String]? {
        guard let request = requests.last(where: { $0.method == "PUT" && $0.path.hasSuffix("/api/notifications/mutes") }),
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
    private func makeService(
        tokenProvider: any TokenProviding = FakeTokenProvider()
    ) -> (PushRegistrationService, UserDefaults) {
        let suite = "push-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let service = PushRegistrationService(
            tokenProvider: tokenProvider,
            apiBaseURL: "https://example.test",
            bundleID: "dev.cmux.ios",
            apnsEnvironment: "sandbox",
            suiteName: suite,
            session: URLSession(configuration: configuration)
        )
        return (service, defaults)
    }

    @Test func disabledByDefault() async {
        let (service, _) = makeService()
        #expect(await service.isEnabled == false)
    }

    @Test func registeringWhileDisabledCachesButDoesNotUpload() async {
        await RecordingURLProtocol.recorder.reset()
        let (service, _) = makeService()
        await service.register(deviceToken: Data([0xAB, 0xCD]))
        // No upload because notifications are off.
        #expect(await RecordingURLProtocol.recorder.methods.isEmpty)
    }

    @Test func enablingUploadsCachedToken() async {
        await RecordingURLProtocol.recorder.reset()
        let (service, defaults) = makeService()
        await service.register(deviceToken: Data([0xAB, 0xCD]))
        await service.setEnabled(true)
        #expect(defaults.bool(forKey: "cmux.notifications.pushEnabled"))
        #expect(await RecordingURLProtocol.recorder.methods.contains("POST"))
    }

    @Test func disablingDeletesServerToken() async {
        await RecordingURLProtocol.recorder.reset()
        let (service, _) = makeService()
        await service.register(deviceToken: Data([0xAB, 0xCD]))
        await service.setEnabled(true)
        await service.setEnabled(false)
        #expect(await RecordingURLProtocol.recorder.methods.contains("DELETE"))
    }

    // MARK: - Per-workspace mute

    @Test func mutedWorkspacesEmptyByDefault() async {
        let (service, _) = makeService()
        #expect(await service.mutedWorkspaceIDs.isEmpty)
    }

    @Test func mutingPersistsAndUploadsFullSet() async {
        await RecordingURLProtocol.recorder.reset()
        let (service, _) = makeService()
        await service.setWorkspaceMuted("ws-a", muted: true)
        #expect(await service.mutedWorkspaceIDs == ["ws-a"])
        // The mute sync is a full-set idempotent replace via PUT.
        #expect(await RecordingURLProtocol.recorder.lastMutedWorkspaceIDs() == ["ws-a"])

        await service.setWorkspaceMuted("ws-b", muted: true)
        #expect(await service.mutedWorkspaceIDs == ["ws-a", "ws-b"])
        // Sorted full set, not a per-workspace delta.
        #expect(await RecordingURLProtocol.recorder.lastMutedWorkspaceIDs() == ["ws-a", "ws-b"])
    }

    @Test func unmutingRemovesFromSetAndReuploads() async {
        await RecordingURLProtocol.recorder.reset()
        let (service, _) = makeService()
        await service.setWorkspaceMuted("ws-a", muted: true)
        await service.setWorkspaceMuted("ws-b", muted: true)
        await service.setWorkspaceMuted("ws-a", muted: false)
        #expect(await service.mutedWorkspaceIDs == ["ws-b"])
        #expect(await RecordingURLProtocol.recorder.lastMutedWorkspaceIDs() == ["ws-b"])
    }

    @Test func mutedSetSurvivesAcrossServiceInstances() async {
        let suite = "push-mute-\(UUID().uuidString)"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        func makeOne() -> PushRegistrationService {
            PushRegistrationService(
                tokenProvider: FakeTokenProvider(),
                apiBaseURL: "https://example.test",
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
        await RecordingURLProtocol.recorder.reset()
        // No tokens → upload is skipped, but the local choice must persist so the
        // next sign-in re-uploads it.
        let (service, _) = makeService(tokenProvider: FakeTokenProvider(access: nil, refresh: nil))
        await service.setWorkspaceMuted("ws-a", muted: true)
        #expect(await service.mutedWorkspaceIDs == ["ws-a"])
        #expect(await RecordingURLProtocol.recorder.requests.isEmpty)
    }
}
