import CmuxInstallAuthCore
import CryptoKit
public import Foundation

/// A short-lived cmux access token for one team, for a person or agent outside
/// the app (`cmux auth token`, cmux-platform#111): the platform API and the
/// hosted MCP take it as `Authorization: Bearer`. It is a fresh install token
/// (ES256, issuer `https://cmux-api/<environment>`, audience `api`, about ten
/// minutes; the Mac grant, never `execute`), minted from this Mac's install key
/// with a `team` claim. No refresh token exists: the caller asks again.
public struct CloudAccessToken: Sendable, Equatable {
    public var accessToken: String
    public var team: String
    /// The token's `sub` (the backend user id), when the token says.
    public var user: String?
    /// The token's `exp`, when the token says.
    public var expiresAt: Date?

    public enum Failure: Error, Equatable, Sendable {
        /// No user is signed in, or the session ended during the mint.
        case signedOut
        /// No team was asked for and the install's own token names none.
        case noTeam
        /// The asked team is not a backend team id (`team_` and 20 hex digits).
        case invalidTeam
        /// The owner refused the mint (for example `auth.forbidden`: not a member).
        case refused(String)
        /// The team needs a newer app.
        case clientTooOld(minimumVersion: String?)
        /// The owner did not answer.
        case unreachable
        /// The owner answered something this client will not use.
        case badReply
        /// The device is restricted to a managed team (`RestrictToManagedTeam`) and the ask
        /// names another team, or the managed team is not the active one.
        case managed

        /// The stable code a caller branches on (the `auth.token` socket error's code).
        public var code: String {
            switch self {
            case .signedOut: "not_signed_in"
            case .noTeam: "no_team"
            case .invalidTeam: "invalid_params"
            case .refused: "forbidden"
            case .clientTooOld: "client_too_old"
            case .unreachable: "unavailable"
            case .badReply: "bad_reply"
            case .managed: "managed"
            }
        }

        /// The owner's refusal code, or the minimum app version, when there is one.
        public var detail: String? {
            switch self {
            case .refused(let code): String(code.prefix(80))
            case .clientTooOld(let minimum): minimum
            default: nil
            }
        }
    }

    /// `token` with its claims read (unverified: the API verifies it).
    public init(token: String, team: String) {
        accessToken = token
        self.team = team
        let claims = Self.claims(of: token)
        user = (claims?["sub"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        expiresAt = (claims?["exp"] as? NSNumber).map(\.doubleValue)
            .flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
    }

    /// A backend team id: `team_` and 20 lowercase hex digits (the owner's form).
    public static func isTeam(_ value: String) -> Bool {
        value.utf8.count == 25 && value.hasPrefix("team_") && value.dropFirst(5).allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// The backend team to mint for, from the app's team state (Stack ids): the asked team, else
    /// the active team, else nil (the install's own, personal team). A device restricted to a
    /// managed team mints only for that team, and only while it is the active one, as every other
    /// Cloud call on it (ActiveTeam.refusal(requesting:)).
    public static func team(requested: String?, activeStackTeam: String?, managedStackTeam: String?,
                            stackProjectID: String) throws -> String? {
        let backend = { backendTeamID(stackProjectID: stackProjectID, stackTeamID: $0) }
        if let managed = managedStackTeam {
            guard activeStackTeam == managed else { throw Failure.managed }
            let only = backend(managed)
            if let requested, requested != only { throw Failure.managed }
            return only
        }
        return requested ?? activeStackTeam.map(backend)
    }

    /// The backend's id for a Stack team (the API's `stackTeamIdFor`; CloudIdentity.workerTeamID).
    public static func backendTeamID(stackProjectID: String, stackTeamID: String) -> String {
        let digest = SHA256.hash(data: Data("stack-team:\(stackProjectID):\(stackTeamID.lowercased())".utf8))
        return "team_" + digest.map { String(format: "%02x", $0) }.joined().prefix(20)
    }

    /// The failure an install mint threw, as one of ours.
    static func failure(_ error: any Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if error as? MacInstallIdentity.Failure == .signedOut { return .signedOut }
        guard let install = error as? InstallAuthError else { return .badReply }
        switch install {
        case .noSession, .userMismatch: return .signedOut
        case .refused(let code): return isTransient(code) ? .unreachable : .refused(code)
        case .clientTooOld(let minimum): return .clientTooOld(minimumVersion: minimum)
        case .transport: return .unreachable
        case .invalidPublicKey, .unexpectedChallenge, .malformedReply: return .badReply
        }
    }

    /// A refusal that is the service's trouble, not the account's: a 5xx or 429 status with no
    /// owner code (`http_503`), or a rate limit. The caller retries those; it never reads them
    /// as "not a member of the team".
    static func isTransient(_ code: String) -> Bool {
        if code == "http_429" || code.contains("rate_limit") { return true }
        guard code.hasPrefix("http_5"), code.count == 8 else { return false }
        return code.dropFirst(5).allSatisfy(\.isNumber)
    }

    private static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Data(base64URLEncoded: String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }
}

extension MacInstallIdentity {
    /// A fresh access token for `team`, or for the team of the install's own
    /// token when `team` is nil. Every call mints (a full lifetime); throws
    /// only ``CloudAccessToken/Failure``.
    public func accessToken(team requested: String?) async throws -> CloudAccessToken {
        if let requested, !CloudAccessToken.isTeam(requested) { throw CloudAccessToken.Failure.invalidTeam }
        do {
            let team: String
            if let requested {
                team = requested
            } else {
                guard let own = Self.team(ofToken: try await installToken()) else { throw CloudAccessToken.Failure.noTeam }
                team = own
            }
            return CloudAccessToken(token: try await installToken(team: team), team: team)
        } catch {
            throw CloudAccessToken.failure(error)
        }
    }
}

extension CloudAuth {
    /// The backend team `cmux auth token` mints for (``CloudAccessToken/team(requested:activeStackTeam:managedStackTeam:stackProjectID:)``):
    /// the asked team, else the active one; a managed device only its managed team.
    public func accessTokenTeam(requested: String?) throws -> String? {
        try CloudAccessToken.team(requested: requested, activeStackTeam: activeTeam.id, managedStackTeam: managedTeamID,
                                  stackProjectID: configuration.stackProjectID)
    }
}
