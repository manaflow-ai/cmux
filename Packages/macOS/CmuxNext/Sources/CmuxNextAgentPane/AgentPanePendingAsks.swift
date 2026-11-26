import CmuxNextPages
import CmuxNextSettings
public import Foundation

/// `chat.asks.pending {sessionId}`: the permission requests acpmux holds open for one chat, for the
/// pane's Needs you list (webviews `needsYou/asks.ts`). The pane's relay never sends `_acpmux/info`
/// (it is not in ``AcpmuxPaneMethods/requests``), so the host reads it itself and hands the page
/// only each entry's `permissionId`, `request`, `turnId` and `groupId`: what
/// `_acpmux/permission_pending` already tells the pane's watch of every chat. It only reads;
/// nothing is answered here.
///
/// The read goes to the pane's own acpmux (``AgentPaneModel/pendingAsksSocket``), the daemon its
/// chat lives on: this app's main daemon for a chat on this Mac, the Chief home's own daemon for a
/// Chief chat (`ChiefHomeAcpmux`, its own `ACPMUX_HOME`). A pane never reads another daemon's
/// chats, and a reread of a Chief chat sees its answers (PR #22646 review).
///
/// The read names the chat `local/<id>`, acpmux's qualified id for one of the daemon's own
/// sessions (`session_identity.rs`, hub `resolve`). A chat on another computer (an SSH or Cloud
/// peer's) is listed by the pane's daemon too, and a read naming it by its bare id would be
/// forwarded to that computer's daemon (`server/peer_forward.rs`); `local/<id>` never resolves
/// to it, so its asks are never read here (PR #22646 review). Only that computer answers them.
/// A peer may itself be named `local`, and acpmux keys its rows `local/<id>`, so a reply that names
/// a `peer` (every forwarded reply does, `peer_forward.rs`; a daemon's own chat never does) is
/// refused too.
@MainActor
public final class AgentPanePendingAsks {
    /// Reads `_acpmux/info` for `session` (a `local/<id>`, ``localSession(_:)``) from the acpmux
    /// listening on `socket`: its result, or nil when acpmux did not answer (no such session of its
    /// own there, no daemon).
    public typealias Read = @MainActor (_ socket: String, _ session: String) async -> [String: Any]?

    /// The keys of a pending entry the page gets.
    static let entryKeys: Set<String> = ["permissionId", "request", "turnId", "groupId"]
    /// Most entries one reply carries.
    static let maximumEntries = 64
    /// Longest session id the op takes (acpmux ids are UUIDs).
    static let maximumSession = 256
    /// acpmux's host name for the daemon's own sessions (`LOCAL_HOST_ID`).
    static let localHost = "local/"

    /// `session` as acpmux's qualified id for the daemon's own session (`local/<id>`): a bare id is
    /// qualified, one already qualified as local is kept, and an id naming another host (or any
    /// other `/`) is nil, so it is never sent.
    static func localSession(_ session: String) -> String? {
        let mux = session.hasPrefix(localHost) ? String(session.dropFirst(localHost.count)) : session
        guard !mux.isEmpty, !mux.contains("/") else { return nil }
        return localHost + mux
    }

    private let readInfo: Read

    public init(read: @escaping Read) {
        readInfo = read
    }

    /// Reads with one short plain connection to the socket per read, as the agent CLI card's
    /// requests on the same socket do (``AgentPaneHarnessCard``). `_acpmux/info` needs no person
    /// proof (acpmux `server/requests.rs` answers it on any local connection), so none is made:
    /// this read holds no more authority than the pane's own socket gives.
    public convenience init() {
        self.init { socket, session in
            try? await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/info", params: ["sessionId": session],
                                               deadline: .seconds(5))
        }
    }

    /// The op's answer: `{pending: [entry]}`, or null when the chat could not be read. Throws for
    /// params that are not exactly a session id. `socket`: the calling pane's own acpmux
    /// (``AgentPaneModel/pendingAsksSocket``); nil (a chat on another machine, a pane before its
    /// handshake, a closed pane) answers null for every id and reads nothing.
    func reply(_ params: JSONValue, op: String, socket: String?) async throws -> JSONValue {
        guard let body = params.foundationObject as? [String: Any], Set(body.keys) == ["sessionId"],
              let session = body["sessionId"] as? String, !session.isEmpty, session.utf8.count <= Self.maximumSession
        else { throw PageError.invalidParams(op) }
        guard let socket, !socket.isEmpty else { return .null }
        return await pending(of: session, at: socket)
    }

    /// `session`'s open requests on the acpmux at `socket`, filtered to ``entryKeys``.
    func pending(of session: String, at socket: String) async -> JSONValue {
        guard let local = Self.localSession(session),
              let info = await readInfo(socket, local), info["peer"] == nil, let pending = info["pending"] as? [[String: Any]] else { return .null }
        let entries = pending.prefix(Self.maximumEntries).map { entry in entry.filter { Self.entryKeys.contains($0.key) } }
        return JSONValue(foundation: ["pending": entries]) ?? .null
    }
}

extension AgentPaneModel {
    /// The acpmux socket Needs you reads this pane's chats through (`chat.asks.pending`): the
    /// pane's own daemon from its last handshake (``AgentPaneTransport/acpmuxSocket``, set only for
    /// a connection on this Mac). Nil for a chat on another machine (``remoteChat``, or a
    /// ``RemoteAcpmuxWire`` connection, scoped to that one session) and before the handshake.
    var pendingAsksSocket: String? {
        guard !remoteChat, !transport.remoteWire else { return nil }
        return transport.acpmuxSocket
    }
}
