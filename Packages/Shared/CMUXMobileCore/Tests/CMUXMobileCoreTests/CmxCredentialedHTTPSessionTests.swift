import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CMUXMobileCore

@Suite struct CmxCredentialedHTTPSessionTests {
    @Test func rejects307CredentialHeadersAndBody() throws {
        let source = try #require(URL(string: "https://cmux.example/api/devices"))
        let destination = try #require(URL(string: "https://attacker.example/capture"))
        var redirected = URLRequest(url: destination)
        redirected.httpMethod = "POST"
        redirected.setValue("Bearer access", forHTTPHeaderField: "Authorization")
        redirected.setValue("refresh-secret", forHTTPHeaderField: "X-Stack-Refresh-Token")
        redirected.httpBody = Data(#"{"secret":"body-secret"}"#.utf8)
        let response = try #require(HTTPURLResponse(
            url: source,
            statusCode: 307,
            httpVersion: nil,
            headerFields: ["Location": destination.absoluteString]
        ))
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: source)
        #if canImport(FoundationNetworking)
        // FoundationNetworking's redirect callback takes a `@Sendable` handler.
        let recorder = RedirectCompletionRecorder(forwardedRequest: redirected)

        CmxCredentialedHTTPRedirectDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirected
        ) { request in
            recorder.record(request)
        }

        #expect(recorder.completionCalled)
        #expect(recorder.forwardedRequest == nil)
        #else
        var completionCalled = false
        var forwardedRequest: URLRequest? = redirected

        CmxCredentialedHTTPRedirectDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirected
        ) { request in
            completionCalled = true
            forwardedRequest = request
        }

        #expect(completionCalled)
        #expect(forwardedRequest == nil)
        #endif
    }

    @Test func rejectsDeclaredOversizedResponseBeforeBufferingIt() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedCredentialedHTTPURLProtocol.self]
        let session = CmxCredentialedHTTPSession(configuration: configuration)
        let url = try #require(URL(string: "https://cmux.example/api/devices"))

        await #expect(throws: CmxCredentialedHTTPSessionError.responseTooLarge) {
            _ = try await session.data(for: URLRequest(url: url))
        }
    }

    @Test func rejectsOversizedResponseWithoutDeclaredLength() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UndeclaredOversizedCredentialedHTTPURLProtocol.self]
        let session = CmxCredentialedHTTPSession(
            configuration: configuration,
            maximumResponseByteCount: 8
        )
        let url = try #require(URL(string: "https://cmux.example/api/devices"))

        await #expect(throws: CmxCredentialedHTTPSessionError.responseTooLarge) {
            _ = try await session.data(for: URLRequest(url: url))
        }
    }
}

#if canImport(FoundationNetworking)
private final class RedirectCompletionRecorder: @unchecked Sendable {
    private(set) var completionCalled = false
    private(set) var forwardedRequest: URLRequest?

    init(forwardedRequest: URLRequest) {
        self.forwardedRequest = forwardedRequest
    }

    func record(_ request: URLRequest?) {
        completionCalled = true
        forwardedRequest = request
    }
}
#endif

private final class OversizedCredentialedHTTPURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Length": "4194305"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("must-not-buffer".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class UndeclaredOversizedCredentialedHTTPURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: [:]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ninebytes".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
