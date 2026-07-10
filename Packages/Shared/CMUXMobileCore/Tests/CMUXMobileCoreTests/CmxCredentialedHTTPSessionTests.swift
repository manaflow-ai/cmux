import Foundation
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
    }
}
