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

    /// A mint that gave no token, and the backend team it was for (nil when even that is unknown), so the
    /// refusal names the team cmux Cloud refused, never the team the caller asked for (nil: the app's own).
    public struct Refusal: Error, Equatable, Sendable {
        public var failure: Failure
        public var team: String?
    }
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

    /// `token` with its claims read (unverified: the API verifies it; Rust's `identity::claims`).
    public init(token: String, team: String) {
        struct Claims: Decodable { var user: String?, expiresAt: Double? }
        accessToken = token
        self.team = team
        let claims = CloudStartCore().call("cloud_identity_token", ["token": token], as: Claims.self)
        user = claims?.user
        expiresAt = claims?.expiresAt.map { Date(timeIntervalSince1970: $0) }
    }

    private struct Check: Decodable { var isTeam: Bool?, transient: Bool? }

    /// A backend team id: `team_` and 20 lowercase hex digits (Rust's `identity::is_team`).
    public static func isTeam(_ value: String) -> Bool {
        CloudStartCore().call("cloud_identity_check", ["team": value], as: Check.self)?.isTeam ?? false
    }

    /// The backend team to mint for, from the app's team state (Stack ids; Rust's `identity::mint_team`): the asked
    /// team, else the active team, else nil (the install's own, personal team). A device restricted to a managed team
    /// mints only for that team, and only while it is the active one, as every other Cloud call on it.
    public static func team(requested: String?, activeStackTeam: String?, managedStackTeam: String?,
                            stackProjectID: String) throws -> String? {
        struct Request: Encodable { var requested: String?, activeStackTeam: String?, managedStackTeam: String?, stackProjectId: String }
        struct Reply: Decodable { var team: String?, refusal: String? }
        let request = Request(requested: requested, activeStackTeam: activeStackTeam, managedStackTeam: managedStackTeam,
                              stackProjectId: stackProjectID)
        guard let reply = CloudStartCore().call("cloud_identity_mint_team", request, as: Reply.self) else { throw Failure.badReply }
        if reply.refusal != nil { throw Failure.managed }
        return reply.team
    }

    /// The backend's id for a Stack user (the API's `userIdFor`, as CloudIdentity.workerUserID): the `creator` a
    /// cmux-next machine record names. Rust has the same rule (cmux-tui-core `cloud_conversations`), but not yet over
    /// the pinned app FFI.
    public static func backendUserID(stackProjectID: String, stackUserID: String) -> String {
        let digest = SHA256.hash(data: Data("stack:\(stackProjectID):\(stackUserID)".utf8))
        return "user_" + digest.map { String(format: "%02x", $0) }.joined().prefix(20)
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

    /// A refusal that is the service's trouble, not the account's (Rust's `identity::is_transient`: a 5xx or 429 with
    /// no owner code, or a rate limit). The caller retries those; it never reads them as "not a member of the team".
    static func isTransient(_ code: String) -> Bool {
        CloudStartCore().call("cloud_identity_check", ["refusalCode": code], as: Check.self)?.transient ?? false
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

    /// `cmux auth token`'s mint: a fresh token from `identity` for the team ``accessTokenTeam(requested:)`` picks.
    /// Throws only ``CloudAccessToken/Refusal``, naming the team it was for: the picked one, else the install
    /// token's own (`cmux whoami` said "team -" for the app's own team, Leo's NIGHTLY, 2026-11-11).
    public func accessToken(requested: String?, identity: MacInstallIdentity) async throws -> CloudAccessToken {
        var team = requested
        do {
            team = try accessTokenTeam(requested: requested)
            return try await identity.accessToken(team: team)
        } catch {
            let failure = error as? CloudAccessToken.Failure ?? .badReply
            if team == nil, let own = try? await identity.installToken() { team = MacInstallIdentity.team(ofToken: own) }
            throw CloudAccessToken.Refusal(failure: failure, team: team)
        }
    }
}
