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

    /// The account rule for a live session, applied only to sessions the
    /// account authority admitted. Nil for every other session, which keeps
    /// the existing team and legacy rules exactly. An account-admitted session
    /// closes when incoming Mac access is off, the route is disabled
    /// (`account` nil), or the account authority no longer authorizes it.
    static func sessionCloses(
        endpoint: String,
        accountAdmitted: Bool,
        account: V2AccountMacAdmissionAuthority?,
        allowsMacAccess: Bool
    ) -> Bool? {
        guard accountAdmitted else { return nil }
        return !(allowsMacAccess && account?.authorizedPeer(endpointID: endpoint) != nil)
    }

    /// Live authorization for an account-admitted Mac session: incoming Mac
    /// access, the remote flag, and the exact admitted tuple must all hold.
    static func sessionStillAuthorized(allowsIncomingAccess: Bool, enabled: Bool, recheck: () -> Bool) -> Bool {
        allowsIncomingAccess && enabled && recheck()
    }

    /// Whether the account directory may run: the remote flag (and Devices
    /// availability) is on, the runtime has observed it on, and no flag-off
    /// withdrawal is still in flight.
    static func directoryActive(flag: Bool, observed: Bool, withdrawalsInFlight: Int) -> Bool {
        flag && observed && withdrawalsInFlight == 0
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
