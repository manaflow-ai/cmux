import CmuxNextActions
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// `auth.token` (`cmux auth token`, cmux-platform#111): its params, answer and refusals.
@Suite struct AuthTokenMethodTests {
    private let team = "team_" + String(repeating: "a", count: 20)

    @Test func theReplyCarriesTheTokenItsExpiryAndNoRefreshToken() throws {
        let grant = AuthTokenGrant(accessToken: "eyJ.eyJ.sig", team: team, user: "user_1",
                                   expiresAt: Date(timeIntervalSince1970: 1_900_000_600),
                                   apiOrigin: try #require(URL(string: "https://cloud-api.cmux.dev")))
        let reply = ControlMethod.authTokenReply(grant, now: Date(timeIntervalSince1970: 1_900_000_060))
        #expect(reply["access_token"]?.stringValue == "eyJ.eyJ.sig")
        #expect(reply["token_type"]?.stringValue == "Bearer")
        #expect(reply["team"]?.stringValue == team)
        #expect(reply["user"]?.stringValue == "user_1")
        #expect(reply["api_origin"]?.stringValue == "https://cloud-api.cmux.dev")
        #expect(reply["expires_in"]?.intValue == 540)
        #expect(reply["expires_at"]?.stringValue == "2030-03-17T17:56:40Z")
        #expect(reply["refresh_token"] == nil)
    }

    @Test func aGarbledExpiryIsClampedAndAMissingOneIsNull() throws {
        let origin = try #require(URL(string: "https://cloud-api.cmux.dev"))
        let far = AuthTokenGrant(accessToken: "t", team: team, user: nil, expiresAt: .distantFuture, apiOrigin: origin)
        #expect(ControlMethod.authTokenReply(far, now: Date())["expires_in"]?.intValue == 86_400)
        let none = AuthTokenGrant(accessToken: "t", team: team, user: nil, expiresAt: nil, apiOrigin: origin)
        let reply = ControlMethod.authTokenReply(none, now: Date())
        #expect(reply["expires_in"]?.isNull == true)
        #expect(reply["user"]?.isNull == true)
    }

    @Test func theTeamParamIsOptionalAndTrimmed() throws {
        #expect(try ControlMethod.authTokenTeam([:]) == nil)
        #expect(try ControlMethod.authTokenTeam(["team": .null]) == nil)
        #expect(try ControlMethod.authTokenTeam(["team": .string("  ")]) == nil)
        #expect(try ControlMethod.authTokenTeam(["team": .string(" \(team) ")]) == team)
        #expect(throws: ControlError.self) { try ControlMethod.authTokenTeam(["team": .number(1)]) }
    }

    @Test func refusalsKeepTheirCodeAndNameTheTeam() {
        for code in ["not_signed_in", "no_team", "invalid_params", "forbidden", "managed", "client_too_old", "unavailable"] {
            let error = ControlMethod.authTokenError(AuthTokenRefusal(code: code), team: team)
            #expect(error.code == code)
            #expect(!error.message.isEmpty)
        }
        let refused = ControlMethod.authTokenError(AuthTokenRefusal(code: "forbidden", detail: "auth.forbidden"), team: team)
        #expect(refused.message.contains(team))
        #expect(refused.data?["detail"]?.stringValue == "auth.forbidden")
        // An answer the app will not use is still `unavailable` to the CLI.
        #expect(ControlMethod.authTokenError(AuthTokenRefusal(code: "bad_reply"), team: nil).code == "unavailable")
    }

    @Test func authTokenIsACloudFeatureMethod() {
        #expect(ActionFeature(controlMethod: "auth.token") == .cloud)
        #expect(ActionFeature(controlMethod: "auth.status") == nil)
        #expect(ControlError.policyRefusal("auth.token", disabled: [.cloud])?.code == "feature.disabled")
        let method = ControlMethod.authToken(disabledFeatures: { [] }, isSignedIn: { true }, mint: { _ in throw AuthTokenRefusal(code: "no_team") })
        #expect(method.name == "auth.token")
    }
}
