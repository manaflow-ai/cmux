@testable import CmuxNextCloud
import Foundation
import Testing

/// `CloudAuthHandoff` (cmux-api `/v1/auth/handoffs`): what it sends, what it decodes, and how cmux-api's
/// error codes become the socket codes the CLI's exit codes read.
@Suite struct CloudAuthHandoffTests {
    private let origin = URL(string: "https://api.test") ?? URL(fileURLWithPath: "/")
    private let code = "cmh_team_0123456789abcdefabcd.ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk_-0123"

    private final class Box: @unchecked Sendable { var requests: [URLRequest] = [] }

    private func api(status: Int, body: [String: Any], box: Box = Box()) throws -> CloudAuthHandoff {
        let data = try JSONSerialization.data(withJSONObject: body)
        return CloudAuthHandoff(apiOrigin: origin) { request in
            box.requests.append(request)
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
                throw URLError(.badURL)
            }
            return (data, response)
        }
    }

    @Test func mintSendsTheAppsBearerAndDecodesTheCode() async throws {
        let box = Box()
        let minted = try await api(status: 201, body: ["code": code, "expires_at": 1_763_100_000_000, "user": "user_1", "email": "a@b.c", "device": "air-blue"], box: box)
            .mint(stackAccessToken: "stack-access", device: "air-blue")
        #expect(minted == .init(code: code, expiresAt: 1_763_100_000_000, user: "user_1", email: "a@b.c", device: "air-blue"))
        let request = try #require(box.requests.first)
        #expect(request.url?.absoluteString == "https://api.test/v1/auth/handoffs")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer stack-access")
        #expect(!minted.description.contains(code))
    }

    @Test func redeemSendsNoBearerAndNamesTheSignedInUser() async throws {
        let box = Box()
        let redeemed = try await api(status: 200, body: ["already_signed_in": false, "access_token": "a", "refresh_token": "r", "user": "user_1", "stack_user": "s1", "email": "a@b.c", "device": "cmux16"], box: box)
            .redeem(code: code, device: "cmux16", expectedUser: "s1")
        #expect(redeemed.refreshToken == "r" && redeemed.accessToken == "a" && !redeemed.alreadySignedIn)
        #expect(!redeemed.description.contains("\"r\""))
        let request = try #require(box.requests.first)
        #expect(request.value(forHTTPHeaderField: "authorization") == nil)
        let sent = try #require(JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String])
        #expect(sent == ["code": code, "device": "cmux16", "expected_user": "s1"])
    }

    @Test func alreadySignedInNeedsNoTokensButASessionDoes() async throws {
        let already = try await api(status: 200, body: ["already_signed_in": true, "user": "user_1", "stack_user": "s1"]).redeem(code: code, device: nil, expectedUser: "s1")
        #expect(already.alreadySignedIn && already.refreshToken == nil)
        await #expect(throws: CloudAuthHandoff.Refusal(code: "unavailable")) {
            try await api(status: 200, body: ["already_signed_in": false, "user": "user_1", "stack_user": "s1"]).redeem(code: code, device: nil, expectedUser: nil)
        }
    }

    @Test func serverRefusalsBecomeSocketCodes() async {
        let cases: [(Int, String, String)] = [
            (400, "auth_handoff.invalid", "handoff_invalid"), (409, "auth_handoff.other_user", "other_user"),
            (403, "auth.sso_required", "sso_required"), (429, "auth_handoff.rate_limited", "rate_limited"),
            (403, "auth_handoff.human_session_required", "not_signed_in"), (401, "auth.unauthenticated", "not_signed_in"),
            (400, "validation.invalid", "invalid_params"), (503, "auth_handoff.unavailable", "unavailable"), (500, "x", "unavailable"),
        ]
        for (status, server, socket) in cases {
            await #expect(throws: CloudAuthHandoff.Refusal(code: socket)) {
                try await api(status: status, body: ["error": ["code": server, "message": "m"]]).redeem(code: code, device: nil, expectedUser: nil)
            }
        }
        let down = CloudAuthHandoff(apiOrigin: origin) { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: CloudAuthHandoff.Refusal(code: "unavailable")) { try await down.mint(stackAccessToken: "t", device: nil) }
    }
}
