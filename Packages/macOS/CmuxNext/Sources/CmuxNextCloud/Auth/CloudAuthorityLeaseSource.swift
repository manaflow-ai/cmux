import CmuxInstallAuthCore
import Foundation

/// Renews owner-wire credentials under one snapshot's original record; never enters personal registration recovery.
actor CloudAuthorityLeaseSource {
    private let identity: MacInstallIdentity
    private let context: NativeInstallContext
    private let selected: InstallAuthClient
    private let authority: CloudInstallAuthority
    private let version: String
    private let personal: String
    private let team: String
    private let check: @Sendable () async throws -> Void
    private let now: @Sendable () -> Date
    private var userClient: InstallAuthClient?
    private var pending: Task<[CloudAuthorityWireLease], Error>?

    init(identity: MacInstallIdentity, context: NativeInstallContext, selected: InstallAuthClient,
         authority: CloudInstallAuthority, version: String, personal: String, team: String,
         check: @escaping @Sendable () async throws -> Void, now: @escaping @Sendable () -> Date = Date.init) {
        self.identity = identity; self.context = context; self.selected = selected
        self.authority = authority; self.version = version; self.personal = personal; self.team = team
        self.check = check; self.now = now
    }

    func leases() async throws -> [CloudAuthorityWireLease] {
        try Task.checkCancellation()
        if let pending {
            let leases = try await pending.value
            try Task.checkCancellation()
            return leases
        }
        // task-owner: pending; callers join the same bounded HTTP work, including after cancellation.
        let task = Task { try await self.load() }
        pending = task
        defer { pending = nil }
        let leases = try await task.value
        try Task.checkCancellation()
        return leases
    }

    private func load() async throws -> [CloudAuthorityWireLease] {
        try await check()
        let teamToken = try await authority.token(version)
        if userClient == nil {
            userClient = personal == team ? selected : try await identity.scopedClient(team: personal, context: context)
        }
        guard let userClient else { throw CloudTeamScope.Failure.changed }
        let userToken = try await userClient.installToken()
        try await check()
        try await authority.check(version)
        return [
            try CloudAuthorityWireLease(owner: .user, context: context, team: personal, token: userToken, now: now()),
            try CloudAuthorityWireLease(owner: .team, context: context, team: team, token: teamToken, now: now())
        ]
    }
}
