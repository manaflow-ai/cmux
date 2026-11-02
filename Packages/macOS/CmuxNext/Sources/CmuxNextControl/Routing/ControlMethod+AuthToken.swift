public import CmuxNextActions
import CmuxNextSettings
public import Foundation

/// A token `auth.token` hands out: a short-lived cmux access token for one team
/// (cmux-platform#111). The app mints it (CmuxNextCloud's CloudAccessToken).
public struct AuthTokenGrant: Sendable, Equatable {
    public var accessToken: String
    public var team: String
    public var user: String?
    public var expiresAt: Date?
    /// The cmux API that issued it.
    public var apiOrigin: URL

    public init(accessToken: String, team: String, user: String?, expiresAt: Date?, apiOrigin: URL) {
        self.accessToken = accessToken
        self.team = team
        self.user = user
        self.expiresAt = expiresAt
        self.apiOrigin = apiOrigin
    }
}

/// Why the mint gave no token: `code` is the socket error's code (`not_signed_in`, `no_team`,
/// `invalid_params`, `forbidden`, `managed`, `client_too_old`, `unavailable`, `bad_reply`) and `detail`
/// the owner's refusal code or the minimum app version.
public struct AuthTokenRefusal: Error, Sendable, Equatable {
    public var code: String
    public var detail: String?

    public init(code: String, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }
}

extension ControlMethod {
    /// `auth.token` (`cmux auth token [--team T]`, docs/cmux-next/auth-token.md): a fresh
    /// token from the app's signed-in session, so `export CMUX_TOKEN=$(cmux auth token)` works
    /// for the platform API and the hosted MCP. No refresh token and no session leave the app.
    /// Any process this socket admits can ask, as it can already drive Cloud through the app;
    /// off with Cloud (`ActionFeature(controlMethod:)`). Nothing here logs the token.
    public static func authToken(
        disabledFeatures: @escaping @MainActor @Sendable () -> Set<ActionFeature>,
        isSignedIn: @escaping @MainActor @Sendable () -> Bool,
        mint: @escaping @Sendable (_ team: String?) async throws -> AuthTokenGrant
    ) -> ControlMethod {
        .async("auth.token") { call in
            let (disabled, signedIn) = await MainActor.run { (disabledFeatures(), isSignedIn()) }
            if let refusal = ControlError.policyRefusal("auth.token", disabled: disabled) { throw refusal }
            guard signedIn else { throw authTokenError(AuthTokenRefusal(code: "not_signed_in"), team: nil) }
            let team = try authTokenTeam(call.params)
            do {
                return authTokenReply(try await mint(team), now: Date())
            } catch let refusal as AuthTokenRefusal {
                throw authTokenError(refusal, team: team)
            }
        }.withDeadline(.fixed(.seconds(25)))
    }

    /// The asked team (`team`), or nil for the app's own team. Empty reads as not given.
    static func authTokenTeam(_ params: [String: JSONValue]) throws -> String? {
        guard let raw = params["team"], !raw.isNull else { return nil }
        guard let team = raw.stringValue?.trimmingCharacters(in: .whitespaces) else {
            throw authTokenError(AuthTokenRefusal(code: "invalid_params"), team: nil)
        }
        return team.isEmpty ? nil : team
    }

    /// The answer: the token and what a script needs beside it, never a refresh token.
    /// `expires_at` is ISO 8601 UTC, `expires_in` whole seconds from `now`.
    static func authTokenReply(_ grant: AuthTokenGrant, now: Date) -> JSONValue {
        var fields: [String: JSONValue] = [
            "access_token": .string(grant.accessToken),
            "token_type": .string("Bearer"),
            "team": .string(grant.team),
            "user": grant.user.map(JSONValue.string) ?? .null,
            "api_origin": .string(grant.apiOrigin.absoluteString),
            "expires_at": .null,
            "expires_in": .null,
        ]
        if let expiry = grant.expiresAt, expiry.timeIntervalSince(now).isFinite {
            fields["expires_at"] = .string(ISO8601DateFormatter().string(from: expiry))
            // Whole seconds, clamped, so a garbled `exp` reads as at most a day.
            let seconds = min(max(0, expiry.timeIntervalSince(now)), 86_400).rounded(.down)
            fields["expires_in"] = JSONValue(foundation: NSNumber(value: seconds)) ?? .null
        }
        return .object(fields)
    }

    /// A refusal as this socket's error, with its message in the person's language.
    static func authTokenError(_ refusal: AuthTokenRefusal, team: String?) -> ControlError {
        let detail: JSONValue? = refusal.detail.map { ["detail": .string($0)] }
        let message: String = switch refusal.code {
        case "not_signed_in":
            ControlStrings.text("control.authToken.notSignedIn", "Sign in to cmux in the cmux app first.")
        case "no_team":
            ControlStrings.text("control.authToken.noTeam", "Choose a cmux team in the cmux app first, or pass --team.")
        case "invalid_params":
            ControlStrings.text("control.authToken.invalidTeam", "--team takes a cmux team id: team_ and 20 hex digits.")
        case "forbidden":
            ControlStrings.format("control.authToken.refused", "cmux Cloud refused a token for team %@. Check that your account belongs to it.", team ?? "-")
        case "client_too_old":
            ControlStrings.text("control.authToken.clientTooOld", "This team needs a newer cmux. Install the newest cmux, then run cmux auth token again.")
        case "managed":
            ControlStrings.text("control.authToken.managed", "Your organization limits cmux on this Mac to its managed team, so a token for another team isn't available.")
        case "unavailable":
            ControlStrings.text("control.authToken.unreachable", "cmux Cloud didn't answer. Try again in a moment.")
        default:
            ControlStrings.text("control.authToken.badReply", "cmux Cloud sent an answer cmux can't use. Run cmux auth token again.")
        }
        return ControlError(code: refusal.code == "bad_reply" ? "unavailable" : refusal.code, message: message, data: detail)
    }
}
