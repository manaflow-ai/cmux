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
        Task { await RecordingURLProtocol.recorder.record(request) }
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
}

actor RequestRecorder {
    private(set) var methods: [String] = []
    func record(_ request: URLRequest) { methods.append(request.httpMethod ?? "?") }
    func reset() { methods = [] }
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
}
