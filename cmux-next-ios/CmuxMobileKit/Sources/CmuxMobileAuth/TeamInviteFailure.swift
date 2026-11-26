import Foundation
import StackAuth

/// Why joining a team from an invite link (or sending an invite) failed, as a toast says it.
///
/// Stack names the failure in its `x-hexclave-known-error` header (the Swift SDK's
/// ``StackAuthErrorProtocol/code``); the web's accept page reads the same codes
/// (web/services/teams/invitationCode.ts). The SDK turns every transport failure
/// into `network_error`, so that, and a bare offline `URLError`, read as offline.
public enum TeamInviteFailure: Error, Equatable, Sendable {
    /// The code expired or was already used: only a new invite works.
    case expired
    /// The invite was sent to an email this account does not have.
    case otherEmail
    case offline
    case alreadyMember
    /// Anything else (a malformed link, a refused request): the caller's own fallback.
    case other

    public init(_ error: any Error) {
        if let failure = error as? TeamInviteFailure {
            self = failure
        } else if let urlError = error as? URLError {
            self = Self.offlineCodes.contains(urlError.code) ? .offline : .other
        } else if let stack = error as? any StackAuthErrorProtocol {
            self = TeamInviteFailure(code: stack.code)
        } else {
            self = .other
        }
    }

    /// A Stack known-error code (or the SDK's `network_error`).
    public init(code: String) {
        switch code {
        case "VERIFICATION_CODE_EXPIRED", "VERIFICATION_CODE_ALREADY_USED": self = .expired
        case "TEAM_INVITATION_EMAIL_MISMATCH": self = .otherEmail
        case "TEAM_MEMBERSHIP_ALREADY_EXISTS": self = .alreadyMember
        case "network_error": self = .offline
        default: self = .other
        }
    }

    static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
    ]

    /// What the toast says; `fallback` for ``other``.
    public func message(fallback: String) -> String {
        switch self {
        case .expired: "This invite expired. Ask for a new one."
        case .otherEmail: "This invite is for another email."
        case .offline: "You're offline. Try again when you're connected."
        case .alreadyMember: "You're already on this team."
        case .other: fallback
        }
    }
}
