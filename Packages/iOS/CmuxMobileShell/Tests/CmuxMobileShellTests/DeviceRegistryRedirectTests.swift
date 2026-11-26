import Foundation
import Testing
@testable import CmuxMobileShell

@Suite(.serialized)
struct DeviceRegistryRedirectTests {
    @Test func credentialedRegistryRequestNeverFollowsRedirect() async throws {
        let destination = try #require(URL(string: "https://attacker.example/capture"))
        DeviceRegistryRedirectURLProtocol.reset(destination: destination)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceRegistryRedirectURLProtocol.self]
        let service = DeviceRegistryService(
            apiBaseURL: "https://cmux.example",
            deviceID: "ios-device",
            tokenSource: .init(
                accessToken: { "access-token" },
                refreshToken: { "refresh-token" }
            ),
            sessionConfiguration: configuration,
            requestTimeout: 0.1
        )

        _ = await service.listDevices()

        #expect(DeviceRegistryRedirectURLProtocol.capturedDestinationRequests().isEmpty)
    }
}

private final class DeviceRegistryRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var destination: URL?
    private nonisolated(unsafe) static var destinationRequests: [URLRequest] = []

    static func reset(destination: URL) {
        lock.withLock {
            self.destination = destination
            destinationRequests = []
        }
    }

    static func capturedDestinationRequests() -> [URLRequest] {
        lock.withLock { destinationRequests }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let destination = Self.lock.withLock({ Self.destination }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if request.url == destination {
            Self.lock.withLock {
                Self.destinationRequests.append(request)
            }
            let response = HTTPURLResponse(
                url: destination,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"devices":[]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": destination.absoluteString]
        )!
        var redirected = request
        redirected.url = destination
        client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
    }

    override func stopLoading() {}
}
