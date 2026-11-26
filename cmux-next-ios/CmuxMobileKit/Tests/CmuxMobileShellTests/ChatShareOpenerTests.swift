import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileShell

/// The phone opens a share page signed in as its account: the token buys a one-time code from the
/// share host, never travels in the page, and a refusal opens the page signed out.
@Suite(.serialized) struct ChatShareOpenerTests {
    let link = ChatShareLink(url: URL(string: "https://share.cmux.dev/i/0123456789abcdefABCD")!)!

    func session(status: Int, body: String) -> URLSession {
        ChatShareStubProtocol.answer = (status, Data(body.utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatShareStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func signedInTheTokenBuysAHandOffForThePage() async throws {
        let code = "HANDOFF_code-0123456789"
        let page = await ChatShareOpener.page(for: link, token: "tok-1",
                                              session: session(status: 200, body: #"{"handoff":"\#(code)","expires_at":1}"#))
        #expect(page.signedIn)
        #expect(page.url == link.pageURL(handoff: code))
        let request = try #require(ChatShareStubProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url == link.handoffURL)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-1")
        #expect(!page.url.absoluteString.contains("tok-1"))
    }

    @Test func aRefusalOrABadAnswerOpensThePageSignedOut() async {
        for (status, body) in [(401, #"{"error":"unauthorized"}"#), (200, #"{"handoff":"bad code"}"#), (200, "nope")] {
            let page = await ChatShareOpener.page(for: link, token: "tok-1", session: session(status: status, body: body))
            #expect(!page.signedIn)
            #expect(page.url == link.pageURL(handoff: nil))
        }
    }

    @Test func signedOutNothingIsAsked() async {
        ChatShareStubProtocol.lastRequest = nil
        let page = await ChatShareOpener.page(for: link, token: nil, session: session(status: 200, body: "{}"))
        #expect(!page.signedIn && page.url == link.pageURL(handoff: nil))
        #expect(ChatShareStubProtocol.lastRequest == nil)
    }
}

final class ChatShareStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var answer: (Int, Data) = (200, Data())
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.answer.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.answer.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
