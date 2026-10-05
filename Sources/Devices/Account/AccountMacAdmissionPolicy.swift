import CmuxIrxTransport
import Foundation

/// The host runtime's rules for combining the team authority with the
/// same-user Mac authority. Kept free of runtime state so each rule is tested
/// directly.
enum AccountMacAdmissionPolicy {
    /// Whether a team v2 denial may fall through to the same-user Mac
    /// authority. Only an endpoint the team does not know (`.invalidGrant`)
    /// qualifies; a team revocation or expiry is final, and the remote flag
    /// turns the account route off entirely.
    static func allowsFallback(after denial: IrxAdmissionDenied, enabled: Bool) -> Bool {
        enabled && denial.code == .invalidGrant
    }

    /// The inbound v2 judgment: the team authority first, then the same-user
    /// Mac authority only for an endpoint the team does not know. Any other
    /// team denial (revoked, expired) is returned unchanged.
    static func fallbackJudgment(
        team: @escaping IrxGrantJudgment,
        account: IrxGrantJudgment?,
        enabled: @escaping @Sendable () -> Bool
    ) -> IrxGrantJudgment {
        { grant, endpoint in
            do {
                return try team(grant, endpoint)
            } catch let denied as IrxAdmissionDenied {
                guard let account, allowsFallback(after: denied, enabled: enabled()) else { throw denied }
                return try account(grant, endpoint)
            }
        }
    }

    /// Whether a live session admitted only by the same-user Mac authority
    /// closes: it does when incoming Mac access is off. Nil defers to the
    /// existing team and legacy rules, which covers every session the team
    /// knows and every session while the account route is disabled (`account` nil).
    static func sessionCloses(
        endpoint: String,
        team: V2InboundAdmissionAuthority,
        account: V2AccountMacAdmissionAuthority?,
        allowsMacAccess: Bool
    ) -> Bool? {
        guard let account, team.authorizedPeer(endpointID: endpoint) == nil,
              account.authorizedPeer(endpointID: endpoint) != nil else { return nil }
        return !allowsMacAccess
    }

    /// Live authorization for an account-admitted Mac session: incoming Mac
    /// access, the remote flag, and the exact admitted tuple must all hold.
    static func sessionStillAuthorized(allowsIncomingAccess: Bool, enabled: Bool, recheck: () -> Bool) -> Bool {
        allowsIncomingAccess && enabled && recheck()
    }

    /// Credentials the account directory may borrow from a team snapshot:
    /// this generation's unrevoked Mac record, an unexpired ticket, and a Mac
    /// device capability the account service requires before publishing.
    static func credentials(_ cache: V2CachedState, enabled: Bool, now: Date) -> AccountMacDirectoryClient.Credentials? {
        guard enabled, cache.formatVersion == 2, !cache.authorityRevoked,
              let record = cache.device, !record.revoked,
              record.descriptor.identity == cache.identity,
              record.descriptor.metadata.platform == .mac,
              !Set(record.descriptor.metadata.capabilities)
                .isDisjoint(with: ["cmux.mac-devices.v1", "cmux.mac-host.v1"]),
              let ticket = cache.ticket, ticket.expiresAt > Int(now.timeIntervalSince1970) else { return nil }
        return AccountMacDirectoryClient.Credentials(device: record.descriptor, ticket: ticket)
    }
}
