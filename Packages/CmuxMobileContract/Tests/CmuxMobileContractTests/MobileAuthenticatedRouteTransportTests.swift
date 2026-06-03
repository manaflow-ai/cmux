import Foundation
import Testing
@testable import CmuxMobileContract

@MainActor
private final class FakeTokenProvider: AuthTokenProviding {
    var isAuthenticated: Bool
    let token: String
    let throwsOnAccess: Bool

    init(isAuthenticated: Bool = true, token: String = "tok-123", throwsOnAccess: Bool = false) {
        self.isAuthenticated = isAuthenticated
        self.token = token
        self.throwsOnAccess = throwsOnAccess
    }

    struct TokenError: Error {}

    func accessToken() async throws -> String {
        if throwsOnAccess { throw TokenError() }
        return token
    }
}

/// A `URLProtocol` that returns a scripted response and records the issued request.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var lastAuthorizationHeader: String?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastAuthorizationHeader = request.value(forHTTPHeaderField: "Authorization")
        Self.lastBody = request.httpBody ?? request.bodyStreamData()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func bodyStreamData() -> Data? {
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private struct EchoRequest: Encodable, Equatable, Sendable {
    let value: String
}

private struct EchoResponse: Codable, Equatable, Sendable {
    let ok: Bool
}

@MainActor
@Suite(.serialized) struct MobileAuthenticatedRouteTransportTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func attachesBearerTokenAndDecodesResponse() async throws {
        StubURLProtocol.statusCode = 200
        StubURLProtocol.responseBody = try JSONEncoder().encode(EchoResponse(ok: true))
        StubURLProtocol.lastAuthorizationHeader = nil
        StubURLProtocol.lastBody = nil

        let transport = MobileAuthenticatedRouteTransport(
            baseURL: URL(string: "https://example.test")!,
            session: makeSession(),
            tokenProvider: FakeTokenProvider(token: "abc")
        )

        let response = try await transport.send(
            path: "api/mobile/echo",
            body: EchoRequest(value: "hi"),
            responseType: EchoResponse.self
        )

        #expect(response == EchoResponse(ok: true))
        #expect(StubURLProtocol.lastAuthorizationHeader == "Bearer abc")
    }

    @Test func mapsNon2xxToHTTPError() async throws {
        StubURLProtocol.statusCode = 503
        StubURLProtocol.responseBody = try JSONSerialization.data(withJSONObject: ["error": "down"])
        let transport = MobileAuthenticatedRouteTransport(
            baseURL: URL(string: "https://example.test")!,
            session: makeSession(),
            tokenProvider: FakeTokenProvider()
        )

        await #expect(throws: MobileRouteClientError.httpError(503, "down")) {
            _ = try await transport.send(
                path: "api/mobile/echo",
                body: EchoRequest(value: "hi"),
                responseType: EchoResponse.self
            )
        }
    }
}
