import Foundation

@testable import CmuxNextTransport

/// Records each request and answers from a per-test response script.
actor ScriptedBroker {
    private var recorded: [URLRequest] = []
    private let respond: @Sendable (URLRequest) -> (Int, String)

    init(respond: @escaping @Sendable (URLRequest) -> (Int, String)) {
        self.respond = respond
    }

    var requests: [URLRequest] { recorded }

    nonisolated var transport: BrokerCredentialClient.Transport {
        { request in await self.handle(request) }
    }

    private func handle(_ request: URLRequest) -> (Data, URLResponse) {
        recorded.append(request)
        let (status, body) = respond(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
