import CmuxInstallAuthCore
import Foundation

/// One snapshot's scoped token client and live owner fence; versions carry no permission.
actor CloudInstallAuthority {
    private let client: InstallAuthClient
    private let transport: any InstallAuthTransport
    private let headers: [String: String]
    private let context: NativeInstallContext
    private let team: String
    private let boundCheck: @Sendable () async throws -> Void

    init(client: InstallAuthClient, transport: any InstallAuthTransport, headers: [String: String],
         context: NativeInstallContext, team: String, check: @escaping @Sendable () async throws -> Void) {
        self.client = client; self.transport = transport; self.headers = headers
        self.context = context; self.team = team; self.boundCheck = check
    }

    func version() async throws -> String { try await read().version }

    func check(_ expected: String) async throws {
        guard try await read().version == expected else { throw CloudTeamScope.Failure.changed }
    }

    func token(_ expected: String) async throws -> String {
        let current = try await read()
        guard current.version == expected else { throw CloudTeamScope.Failure.changed }
        return current.token
    }

    private func read() async throws -> (version: String, token: String) {
        try await boundCheck()
        // Reuse the existing client's refresh and single-flight behavior within this snapshot.
        let token = try await client.installToken()
        try await boundCheck()
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.utf8.count <= 16_384, pieces.count == 3,
              let payload = Data(base64URLEncoded: String(pieces[1])),
              let claims = try? JSONDecoder().decode(Claims.self, from: payload),
              claims.iss == "https://cmux-api/" + context.environment,
              claims.sub == context.user, claims.inst == context.install, claims.team == team,
              !claims.grant.isEmpty, claims.grant.utf8.count <= 128 else { throw CloudTeamScope.Failure.invalidIdentity }
        var requestHeaders = headers
        requestHeaders["x-cmux-team"] = team
        let reply = try await transport.post("/v1/read", json: Data(#"{"op":"install.authority","params":{}}"#.utf8), bearer: token, headers: requestHeaders)
        try await boundCheck()
        if reply.status == 401 || reply.status == 403 { throw CloudTeamScope.Failure.changed }
        guard reply.status == 200, reply.body.count <= 8_192,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: reply.body),
              envelope.op == "install.authority" else { throw CloudTeamScope.Failure.unavailable }
        let value = envelope.value
        guard value.user == context.user, value.install == context.install, value.team == team,
              value.grant == claims.grant else { throw CloudTeamScope.Failure.invalidIdentity }
        guard value.authority_version.utf8.count == 64,
              value.authority_version.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw CloudTeamScope.Failure.unavailable }
        return (value.authority_version, token)
    }

    private struct Claims: Decodable { let iss: String; let sub: String; let inst: String; let team: String; let grant: String }
    private struct Envelope: Decodable { let op: String; let value: Value }
    private struct Value: Decodable { let user: String; let team: String; let install: String; let grant: String; let authority_version: String }
}
