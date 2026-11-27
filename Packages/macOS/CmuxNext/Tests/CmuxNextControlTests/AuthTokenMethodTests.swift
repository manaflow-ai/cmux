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
        // Msg 3790: a terminal has no button, so signed out the CLI names the command that signs in.
        #expect(ControlMethod.authTokenError(AuthTokenRefusal(code: "not_signed_in"), team: nil).message.contains("cmux cloud sign-in"))
        // An answer the app will not use is still `unavailable` to the CLI.
        #expect(ControlMethod.authTokenError(AuthTokenRefusal(code: "bad_reply"), team: nil).code == "unavailable")
    }

    /// Probe cloud-signed-in-after-update-production, 2026-11-15: a Keychain refusal read "cmux Cloud sent an answer
    /// cmux can't use", and a terminal prints only the message. The cause rides in the code and the text.
    @Test func aLocalFailureNamesItsCauseInTheCodeAndTheText() {
        let cause = "keychain(-25244: Invalid attempt to change the owner of this item.)"
        let local = ControlMethod.authTokenError(AuthTokenRefusal(code: "local_failure", detail: cause), team: nil)
        #expect(local.code == "local_failure")
        #expect(local.message.contains(cause))
        #expect(!local.message.contains("cmux Cloud sent an answer"))
        #expect(local.data?["detail"]?.stringValue == cause)
        let reply = ControlMethod.authTokenError(AuthTokenRefusal(code: "bad_reply", detail: "unexpected_challenge"), team: nil)
        #expect(reply.message.contains("unexpected_challenge"))
        // A refusal's detail is the owner's code, already in its own words: not repeated.
        let refused = ControlMethod.authTokenError(AuthTokenRefusal(code: "forbidden", detail: "auth.forbidden"), team: nil)
        #expect(!refused.message.contains("(auth.forbidden)"))
    }

    /// Probes cloud-chat-replies-production and kin, 2026-11-24 and 11-25: the probe account's full head answered
    /// install.register `owner.state_full`, and the CLI said "Check that your account belongs to it", so the class read
    /// as a stale team for a day. A non-membership owner code names itself and gives no membership advice.
    @Test func aNonMembershipRefusalNamesItsOwnerCode() {
        let full = ControlMethod.authTokenError(AuthTokenRefusal(code: "forbidden", detail: "owner.state_full", team: team), team: nil)
        #expect(full.code == "forbidden")
        #expect(full.message.contains(team))
        #expect(full.message.contains("owner.state_full"))
        #expect(!full.message.contains("belongs to it"))
        #expect(full.data?["detail"]?.stringValue == "owner.state_full")
        for membership in [nil, "auth.forbidden", "team.not_member"] as [String?] {
            let error = ControlMethod.authTokenError(AuthTokenRefusal(code: "forbidden", detail: membership, team: team), team: nil)
            #expect(error.message.contains("belongs to it"))
        }
    }

    /// Leo's NIGHTLY, 2026-11-11: `cmux whoami` (no `--team`) said "refused a token for team -". The refusal
    /// names the team the mint was for, the app's own team too.
    @Test func aRefusalForTheAppsOwnTeamNamesThatTeam() {
        let own = AuthTokenRefusal(code: "forbidden", detail: "auth.forbidden", team: "team_0123456789abcdef0123")
        let error = ControlMethod.authTokenError(own, team: nil)
        #expect(error.code == "forbidden")
        #expect(error.message.contains("team_0123456789abcdef0123"))
        #expect(!error.message.contains("team -"))
        // The team the mint was for wins over the asked one.
        #expect(ControlMethod.authTokenError(own, team: team).message.contains("team_0123456789abcdef0123"))
    }

    @Test func authTokenIsACloudFeatureMethod() {
        #expect(ActionFeature(controlMethod: "auth.token") == .cloud)
        #expect(ActionFeature(controlMethod: "auth.status") == nil)
        #expect(ControlError.policyRefusal("auth.token", disabled: [.cloud])?.code == "feature.disabled")
        let method = ControlMethod.authToken(disabledFeatures: { [] }, isSignedIn: { true }, mint: { _ in throw AuthTokenRefusal(code: "no_team") })
        #expect(method.name == "auth.token")
    }
}
