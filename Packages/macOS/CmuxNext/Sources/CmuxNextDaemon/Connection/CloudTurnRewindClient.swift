import Foundation

/// A Cloud chat's turn checkpoints on this Mac's daemon: `cloud.owner.turn_checkpoint` and
/// `cloud.owner.turn_rewind` (capability `cloud-api-v1`), whose sequence (connection read, first
/// bind, generation fence, finish, retention, same-key rewind retries) is cmux-cloud-api's
/// `turns.rs`. The request carries the person's own Cloud token; the daemon keeps none and never
/// echoes it.
public struct CloudTurnRewindClient: Sendable {
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// The person's Cloud session for one call: the owner API's base URL, the access token and the team.
    public struct Credential: Sendable {
        public var api: String
        public var accessToken: String
        public var team: String?

        public init(api: String, accessToken: String, team: String?) {
            (self.api, self.accessToken, self.team) = (api, accessToken, team)
        }
    }

    /// Bounds the daemon's own deadlines (a checkpoint's 3 min, a rewind's 5 min of same-key retries).
    static let timeout: Duration = .seconds(420)

    /// `owner.turn_checkpoint {workspace, carrierMachine, session, turnSeq, clientKey}`: answers
    /// `{turn, turnSeq, snapshotId, generation, machineId, connectionMachine, imported, seconds, retention}`.
    public func checkpoint(_ credential: Credential, workspace: String, carrierMachine: String, session: String,
                           turnSeq: Int, clientKey: String) async throws -> JSONValue {
        try await call("cloud.owner.turn_checkpoint", credential, key: clientKey, args: [
            "workspace": .string(workspace), "carrierMachine": .string(carrierMachine), "session": .string(session),
            "turnSeq": .number(Double(turnSeq)), "clientKey": .string(clientKey),
        ])
    }

    /// `owner.turn_rewind {workspace, session, turnSeq, clientKey}`: answers
    /// `{turn, turnSeq, generation, machineId, connectionMachine, rewindId, seconds}`.
    public func rewind(_ credential: Credential, workspace: String, session: String, turnSeq: Int,
                       clientKey: String) async throws -> JSONValue {
        try await call("cloud.owner.turn_rewind", credential, key: clientKey, args: [
            "workspace": .string(workspace), "session": .string(session),
            "turnSeq": .number(Double(turnSeq)), "clientKey": .string(clientKey),
        ])
    }

    /// `owner.turns {workspace, session}`: the session's ready checkpoints' turn numbers, newest first
    /// (none for a read that failed: the page then offers no rewind until its next handshake).
    public func readyTurns(_ credential: Credential, workspace: String, session: String) async -> [Int] {
        let sent = Self.params(credential, args: ["workspace": .string(workspace), "session": .string(session)])
        let listed = try? await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: "cloud.owner.turns", params: sent, idempotencyKey: nil)
        }, as: JSONValue.self, timeout: .seconds(10), requiring: "cloud-api-v1")
        guard case .object(let answer)? = listed, case .array(let captures)? = answer["captures"] else { return [] }
        return captures.compactMap { capture in
            guard case .object(let fields) = capture, case .number(let seq)? = fields["turnSeq"] else { return nil }
            return Int(exactly: seq)
        }
    }

    private static func params(_ credential: Credential, args: [String: JSONValue]) -> [String: JSONValue] {
        var params: [String: JSONValue] = [
            "api": .string(credential.api), "auth": .string("owner"), "access_token": .string(credential.accessToken),
            "args": .object(args),
        ]
        if let team = credential.team { params["team"] = .string(team) }
        return params
    }

    private func call(_ operation: String, _ credential: Credential, key: String, args: [String: JSONValue]) async throws -> JSONValue {
        let sent = Self.params(credential, args: args)
        return try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: operation, params: sent, idempotencyKey: key)
        }, as: ResourceMutationResult<JSONValue>.self, timeout: Self.timeout, requiring: "cloud-api-v1").value
    }
}
