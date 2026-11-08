import CmuxCore
import Foundation
import Testing

@Suite("ManagedProxySessionDelegate")
struct ManagedProxySessionDelegateTests {
    @Test("proxy challenges are cancelled instead of reaching the system prompt", arguments: [
        NSURLAuthenticationMethodHTTPBasic,
        NSURLAuthenticationMethodDefault,
    ])
    func cancelsProxyChallenges(method: String) async {
        let protectionSpace = URLProtectionSpace(
            proxyHost: "127.0.0.1",
            port: 9876,
            type: NSURLProtectionSpaceHTTPSProxy,
            realm: "cmux",
            authenticationMethod: method
        )

        let (disposition, credential) = await Self.answer(protectionSpace)

        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil)
    }

    @Test("server challenges keep the default handling")
    func leavesServerChallengesAlone() async {
        let protectionSpace = URLProtectionSpace(
            host: "example.test",
            port: 443,
            protocol: NSURLProtectionSpaceHTTPS,
            realm: "site",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )

        let (disposition, credential) = await Self.answer(protectionSpace)

        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    private static func answer(
        _ protectionSpace: URLProtectionSpace
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: UnusedChallengeSender()
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://example.test/")!)
        return await ManagedProxySessionDelegate().urlSession(session, task: task, didReceive: challenge)
    }
}

private final class UnusedChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
