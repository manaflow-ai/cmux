import Foundation
import Testing
@testable import CmuxVoice

@Suite struct HTTPRealtimeVoiceClientSecretProviderTests {
    @Test func sendsStackTokensAndAcceptsAValidEphemeralCredential() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = RealtimeVoiceHTTPStub(
            responseData: Data(
                #"{"value":"ek_ephemeral","expires_at":1800000060,"model":"gpt-realtime-2.1"}"#.utf8
            ),
            statusCode: 200
        )
        let provider = HTTPRealtimeVoiceClientSecretProvider(
            apiBaseURL: "https://cmux.test/",
            tokenSource: RealtimeVoiceTokenSource(
                accessToken: { "access-token" },
                refreshToken: { "refresh-token" }
            ),
            session: session,
            now: { now }
        )

        let secret = try await provider.fetchClientSecret()

        #expect(secret.value == "ek_ephemeral")
        #expect(secret.model == "gpt-realtime-2.1")
        let request = try #require(await session.lastRequest())
        #expect(request.url?.absoluteString == "https://cmux.test/api/realtime/client-secret")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "X-Stack-Refresh-Token") == "refresh-token")
    }

    @Test func rejectsAStandardOrExpiredCredential() async {
        let responses = [
            #"{"value":"sk_standard","expires_at":1800000060,"model":"gpt-realtime-2.1"}"#,
            #"{"value":"ek_expired","expires_at":1799999999,"model":"gpt-realtime-2.1"}"#,
            #"{"value":"ek_wrong_model","expires_at":1800000060,"model":"gpt-realtime"}"#,
        ]
        for response in responses {
            let provider = HTTPRealtimeVoiceClientSecretProvider(
                apiBaseURL: "https://cmux.test",
                tokenSource: RealtimeVoiceTokenSource(
                    accessToken: { "access" },
                    refreshToken: { "refresh" }
                ),
                session: RealtimeVoiceHTTPStub(
                    responseData: Data(response.utf8),
                    statusCode: 200
                ),
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            )
            await #expect(throws: RealtimeVoiceClientSecretError.invalidResponse) {
                _ = try await provider.fetchClientSecret()
            }
        }
    }

    @Test func classifiesAuthenticationAndRateLimitResponses() async {
        for (status, expected) in [
            (401, RealtimeVoiceClientSecretError.notAuthenticated),
            (429, RealtimeVoiceClientSecretError.rateLimited),
            (503, RealtimeVoiceClientSecretError.serviceUnavailable),
        ] {
            let provider = HTTPRealtimeVoiceClientSecretProvider(
                apiBaseURL: "https://cmux.test",
                tokenSource: RealtimeVoiceTokenSource(
                    accessToken: { "access" },
                    refreshToken: { "refresh" }
                ),
                session: RealtimeVoiceHTTPStub(responseData: Data(), statusCode: status)
            )
            await #expect(throws: expected) {
                _ = try await provider.fetchClientSecret()
            }
        }
    }
}

private actor RealtimeVoiceHTTPStub: RealtimeVoiceHTTPSession {
    private let responseData: Data
    private let statusCode: Int
    private var request: URLRequest?

    init(responseData: Data, statusCode: Int) {
        self.responseData = responseData
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["content-type": "application/json"]
        )!
        return (responseData, response)
    }

    func lastRequest() -> URLRequest? {
        request
    }
}
