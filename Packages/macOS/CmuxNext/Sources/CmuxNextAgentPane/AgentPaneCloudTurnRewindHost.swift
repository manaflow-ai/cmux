public import CmuxNextDaemon
public import Foundation

/// The app's side of a Cloud chat's turn checkpoints (``AgentPaneCloudTurnRewind``): it resolves the
/// chat's workspace and machine and passes the person's Cloud token to the daemon's
/// `cloud.owner.turn_checkpoint` / `turn_rewind` / `turns` (cmux-cloud-api `turns.rs`, which owns
/// the sequence). The app hands in only what it alone holds: the setting and sign-in, the chat's
/// place, the local connection and the token, which lives in the app's Keychain.
@MainActor
public struct AgentPaneCloudTurnRewindHost {
    /// The platform workspace of a Cloud chat and the Cloud machine it runs on.
    public typealias Place = (workspace: String, machine: String)

    let isOn: @MainActor () -> Bool
    let place: @MainActor (_ chat: String, _ session: String) -> Place?
    let connection: @MainActor () -> DaemonConnection?
    let credential: @MainActor () async throws -> CloudTurnRewindClient.Credential

    /// - Parameters:
    ///   - isOn: signed in and `cloud.turnCheckpoints` on (off by default).
    ///   - place: Cloud chat tab `chat` showing `session`'s place, or nil.
    ///   - connection: this Mac's daemon connection.
    ///   - credential: the person's Cloud session for one call.
    public init(isOn: @escaping @MainActor () -> Bool, place: @escaping @MainActor (_ chat: String, _ session: String) -> Place?,
                connection: @escaping @MainActor () -> DaemonConnection?,
                credential: @escaping @MainActor () async throws -> CloudTurnRewindClient.Credential) {
        (self.isOn, self.place, self.connection, self.credential) = (isOn, place, connection, credential)
    }

    /// Whether Cloud chats offer turn checkpoints now.
    public var offered: Bool { isOn() }

    /// A checkpoint or rewind of chat tab `chat` showing `session`: the Rust answer, plus the
    /// prompt row it names (`rowId`).
    public func run(chat: String, session: String, request: AgentPaneCloudTurnRewind) async throws -> [String: Any] {
        guard isOn(), let place = place(chat, session), let connection = connection() else {
            throw NSError(domain: "cloud.turnRewind", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cloud chat is unavailable"])
        }
        let client = CloudTurnRewindClient(connection: connection), credential = try await credential()
        // The platform keys a checkpoint by workspace, session and turn, so the turn names its key; a
        // rewind is a new one each click (the same key would answer the first rewind again).
        let answer: JSONValue
        switch request {
        case .checkpoint:
            answer = try await client.checkpoint(credential, workspace: place.workspace, carrierMachine: place.machine,
                                                 session: session, turnSeq: request.turnSeq, clientKey: "cmux-turn-\(request.turnSeq)")
        case .rewind:
            answer = try await client.rewind(credential, workspace: place.workspace, session: session, turnSeq: request.turnSeq,
                                             clientKey: "cmux-rewind-\(request.turnSeq)-\(UUID().uuidString.prefix(8))")
        }
        var reply = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(answer))) as? [String: Any] ?? [:]
        reply["rowId"] = AgentPaneCloudTurnRewind.rowID(turnSeq: request.turnSeq)
        return reply
    }

    /// The prompt rows of `session` with a checkpoint before them (the ready handshake's
    /// `cloudTurnRewind`); none when off or unreachable.
    public func rows(chat: String, session: String) async -> [String] {
        guard isOn(), let place = place(chat, session), let connection = connection(),
              let credential = try? await credential() else { return [] }
        let turns = await CloudTurnRewindClient(connection: connection).readyTurns(credential, workspace: place.workspace, session: session)
        return turns.map(AgentPaneCloudTurnRewind.rowID(turnSeq:))
    }
}
