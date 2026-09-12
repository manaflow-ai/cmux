import Foundation
import Testing
@testable import CmuxNextTransport

@Suite("Broker credential transport security")
struct BrokerHTTPSecurityTests {
    @Test("Credentialed POST redirects are rejected", arguments: [307, 308])
    func rejectsRedirect(status: Int) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let transport = BrokerCredentialClient.liveTransport(configuration: configuration)
        let server = try CredentialRedirectServer()
        let origin = try await server.start()
        var request = URLRequest(url: origin.appendingPathComponent(String(status)))
        request.httpMethod = "POST"
        request.setValue("access-secret", forHTTPHeaderField: "Authorization")
        request.setValue("refresh-secret", forHTTPHeaderField: "X-Stack-Refresh-Token")
        request.httpBody = Data(#"{"password":"password-secret"}"#.utf8)
        do {
            let (_, response) = try await transport(request)
            #expect((response as? HTTPURLResponse)?.statusCode == status)
            #expect(response.url == request.url)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test("Malformed origins never retain credentials in errors", arguments: [
        "https://user-secret:password-secret@broker.example?query-secret#fragment-secret",
        "http://user-secret:password-secret@broker.example/path-secret",
        "not a URL password-secret?query-secret",
    ])
    func malformedOriginIsRedacted(base: String) async throws {
        let client = BrokerCredentialClient(
            sessionConfig: .init(baseUrl: base, deviceId: "device", appInstanceId: "app",
                                 tag: "test", platform: "mac"),
            tokens: { .init(accessToken: "access", refreshToken: "refresh") },
            identity: .generate(appIdentity: "test", deviceID: "device"),
            transport: { _ in
                Issue.record("Malformed origin must not issue a request")
                throw URLError(.badURL)
            })
        do {
            _ = try await client.mint(preferredUrl: nil)
            Issue.record("Malformed origin was accepted")
        } catch let error as BrokerCredentialClient.BrokerError {
            #expect(!error.description.contains("secret"))
            if case .malformedURL(_, let diagnostic) = error {
                #expect(!diagnostic.contains("secret"))
            } else {
                Issue.record("Expected malformed URL, got \(error)")
            }
        }
    }
}
