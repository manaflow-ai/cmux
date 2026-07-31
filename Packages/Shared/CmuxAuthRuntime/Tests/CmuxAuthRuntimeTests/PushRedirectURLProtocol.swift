import Foundation

/// End-to-end URL loading probe for mutating redirect behavior.
final class PushRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    enum Scenario: Sendable {
        case sameOrigin301
        case crossOrigin308
    }

    static let state = PushRedirectState()
    static let startHost = "push-start.test"
    static let targetHost = "push-target.test"
    static let startPath = "/api/device-tokens"
    static let targetPath = "/canonical/device-tokens"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Task {
            guard let url = request.url else {
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let scenario = await Self.state.scenario
            if url.path == Self.startPath {
                let target: URL
                let status: Int
                switch scenario {
                case .sameOrigin301:
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    components.path = Self.targetPath
                    target = components.url!
                    status = 301
                case .crossOrigin308:
                    target = URL(string: "https://\(Self.targetHost)\(Self.targetPath)")!
                    status = 308
                }
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": target.absoluteString]
                )!
                var proposed = URLRequest(url: target)
                proposed.httpMethod = status == 308 ? request.httpMethod : "GET"
                client?.urlProtocol(self, wasRedirectedTo: proposed, redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
                return
            }

            await Self.state.recordTarget(request)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

actor PushRedirectState {
    private(set) var scenario: PushRedirectURLProtocol.Scenario = .sameOrigin301
    private(set) var targetRequests: [URLRequest] = []

    func reset(_ scenario: PushRedirectURLProtocol.Scenario) {
        self.scenario = scenario
        targetRequests = []
    }

    func recordTarget(_ request: URLRequest) {
        targetRequests.append(request)
    }
}
