import Foundation

/// End-to-end URL loading probe for mutating redirect behavior.
final class PushRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    enum Scenario: Sendable {
        case sameOrigin301
        case sameOrigin302
        case sameOrigin303
        case sameOrigin307
        case sameOrigin308
        case schemeDowngrade307
        case crossHost308
        case portChange302

        var statusCode: Int {
            switch self {
            case .sameOrigin301:
                301
            case .sameOrigin302, .portChange302:
                302
            case .sameOrigin303:
                303
            case .sameOrigin307, .schemeDowngrade307:
                307
            case .sameOrigin308, .crossHost308:
                308
            }
        }
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
                switch scenario {
                case .sameOrigin301, .sameOrigin302, .sameOrigin303,
                     .sameOrigin307, .sameOrigin308:
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    components.path = Self.targetPath
                    target = components.url!
                case .schemeDowngrade307:
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    components.scheme = "http"
                    components.path = Self.targetPath
                    target = components.url!
                case .crossHost308:
                    target = URL(string: "https://\(Self.targetHost)\(Self.targetPath)")!
                case .portChange302:
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                    components.port = 444
                    components.path = Self.targetPath
                    target = components.url!
                }
                let status = scenario.statusCode
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": target.absoluteString]
                )!
                var proposed = URLRequest(url: target)
                proposed.httpMethod = [307, 308].contains(status) ? request.httpMethod : "GET"
                client?.urlProtocol(self, wasRedirectedTo: proposed, redirectResponse: response)
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
            client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
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
