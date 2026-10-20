package import CmuxInstallAuthCore
package import Foundation
import CryptoKit

/// Resolves the picker’s opaque Stack reference through the original owner before minting in that team.
package actor CloudTeamScope {
    package struct Selection: Equatable, Sendable {
        let account: String
        let stackTeam: String?
        let generation: UInt64
        package init(account: String, stackTeam: String?, generation: UInt64) {
            self.account = account; self.stackTeam = stackTeam; self.generation = generation
        }
    }
    package struct Snapshot: Sendable {
        package let id: String
        package let selection: Selection
        package let team: String
        package let account: String
        package let generation: UInt64
        package let recheck: @Sendable () async throws -> Void
        package let installToken: @Sendable () async throws -> String
        package let sessionToken: @Sendable () async throws -> String
        package let call: @Sendable (_ path: String, _ body: Data) async throws -> Data
        package let wireLeases: @Sendable () async throws -> [CloudAuthorityWireLease]
        package let refreshAuthority: @Sendable () async throws -> Snapshot
        package let reselectAuthority: @Sendable () async throws -> Snapshot
        let nativeContext: @Sendable () async throws -> NativeInstallContext
    }
    package enum Failure: Error, Equatable { case changed, unavailable, notMember, ssoRequired, invalidIdentity, invalidRequest }

    private let instance = UUID().uuidString
    private let identity: MacInstallIdentity
    private let transport: any InstallAuthTransport
    private let selection: @Sendable () async throws -> Selection
    private let session: InstallAuthClient.SessionToken

    package init(identity: MacInstallIdentity, transport: any InstallAuthTransport,
                 selection: @escaping @Sendable () async throws -> Selection, session: @escaping InstallAuthClient.SessionToken) {
        self.identity = identity; self.transport = transport; self.selection = selection; self.session = session
    }

    package func snapshot() async throws -> Snapshot {
        let selected = try await selection()
        // This binds the install only; no Cloud operation uses the personal token as a fallback.
        let context = try await identity.accountContext()
        return try await snapshot(selected, context: context)
    }

    /// Background authority reconciliation retains the old install and picker selection, without registration recovery.
    private func snapshot(_ selected: Selection, context: NativeInstallContext) async throws -> Snapshot {
        try await check(selected, context)
        guard let personal = MacInstallIdentity.team(ofToken: context.token) else { throw Failure.invalidIdentity }
        guard context.account == selected.account else { throw Failure.changed }
        let bearer = try await session()
        _ = try StackSessionIdentity(bearer, context: context)
        try await check(selected, context)
        let body = Data(#"{"op":"user.teams.list","params":{}}"#.utf8)
        let reply = try await transport.post("/v1/read", json: body, bearer: bearer, headers: identity.requestHeaders)
        try await check(selected, context)
        guard reply.status == 200, reply.body.count <= 1_048_576,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: reply.body),
              envelope.op == "user.teams.list", envelope.value.teams.count <= 101 else { throw Failure.unavailable }
        let listed = envelope.value
        let personalRows = listed.teams.filter { $0.kind == "personal" }
        guard personalRows.count == 1, personalRows[0].id == personal, personalRows[0].stack_team == nil else { throw Failure.invalidIdentity }
        let matches = listed.teams.filter { team in
            if let stack = selected.stackTeam { return team.kind == "stack" && team.stack_team == stack }
            return team.kind == "personal"
        }
        guard matches.count == 1, let found = matches.first else {
            if matches.count > 1 { throw Failure.invalidIdentity }
            throw listed.incomplete ? Failure.unavailable : Failure.notMember
        }
        guard found.id.hasPrefix("team_"), found.id.utf8.count == 25,
              found.id.dropFirst(5).allSatisfy({ "0123456789abcdef".contains($0) }) else { throw Failure.invalidIdentity }
        guard !found.sso_required else { throw Failure.ssoRequired }
        let scoped = try await identity.scopedClient(team: found.id, context: context)
        let authority = CloudInstallAuthority(client: scoped, transport: transport, headers: identity.requestHeaders, context: context, team: found.id) { [weak self] in
            guard let self else { throw Failure.changed }
            try await self.check(selected, context)
        }
        let version = try await authority.version()
        let leases = CloudAuthorityLeaseSource(identity: identity, context: context, selected: scoped,
            authority: authority, version: version, personal: personal, team: found.id) { [weak self] in
                guard let self else { throw Failure.changed }
                try await self.check(selected, context)
            }
        let binding = try JSONEncoder().encode(["cmux-cloud-scope-v2", instance, context.account, context.install,
            context.environment, context.point, String(context.generation), selected.stackTeam ?? "", String(selected.generation), found.id, version])
        let id = SHA256.hash(data: binding).map { String(format: "%02x", $0) }.joined()
        return Snapshot(id: id, selection: selected, team: found.id, account: selected.account, generation: selected.generation, recheck: { [weak self] in
            guard let self else { throw Failure.changed }
            try await self.check(selected, context)
            try await authority.check(version)
        }, installToken: {
            try await authority.token(version)
        }, sessionToken: { [weak self] in
            guard let self else { throw Failure.changed }
            let token = try await self.credential(selected, context)
            try await authority.check(version)
            return token
        }, call: { [weak self] path, body in
            guard let self else { throw Failure.changed }
            return try await self.call(selected, context, team: found.id, authority: authority, version: version, path: path, body: body)
        }, wireLeases: { try await leases.leases() }, refreshAuthority: { [weak self] in
            guard let self else { throw Failure.changed }
            return try await self.snapshot(selected, context: context)
        }, reselectAuthority: { [weak self] in
            guard let self else { throw Failure.changed }
            let next = try await self.selection()
            guard next.account == context.account else { throw Failure.changed }
            return try await self.snapshot(next, context: context)
        }, nativeContext: { [weak self] in
            guard let self else { throw Failure.changed }
            try await self.check(selected, context)
            let token = try await authority.token(version)
            try await self.check(selected, context)
            return NativeInstallContext(account: context.account, user: context.user, install: context.install,
                environment: context.environment, point: context.point, token: token, generation: context.generation,
                secureStorage: context.secureStorage)
        })
    }

    package func token() async throws -> String {
        let scope = try await snapshot()
        return try await scope.installToken()
    }

    private func check(_ selected: Selection, _ context: NativeInstallContext) async throws {
        try await identity.nativeCheck(context)
        guard try await selection() == selected else { throw Failure.changed }
        try Task.checkCancellation()
    }

    private func credential(_ selected: Selection, _ context: NativeInstallContext) async throws -> String {
        try await check(selected, context)
        let token = try await session()
        _ = try StackSessionIdentity(token, context: context)
        try await check(selected, context)
        return token
    }

    /// The snapshot retains its original owner transport and team across every approval step.
    private func call(_ selected: Selection, _ context: NativeInstallContext, team: String, authority: CloudInstallAuthority,
                      version: String, path: String, body: Data) async throws -> Data {
        let path = path.hasPrefix("/") ? path : "/" + path
        guard ["/v1/read", "/v1/ops"].contains(path), body.count <= 1_048_576 else { throw Failure.invalidRequest }
        try await authority.check(version)
        let bearer = try await credential(selected, context)
        var headers = identity.requestHeaders
        headers["x-cmux-team"] = team
        let reply = try await transport.post(path, json: body, bearer: bearer, headers: headers)
        try await authority.check(version)
        return reply.body
    }

    private struct Envelope: Decodable { let op: String; let value: Listing }
    private struct Listing: Decodable { let teams: [Team]; let incomplete: Bool }
    private struct Team: Decodable { let id: String; let kind: String; let stack_team: String?; let sso_required: Bool }
}
