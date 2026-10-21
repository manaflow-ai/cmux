import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// `chat.asks.pending {sessionId}`: the permission requests acpmux holds open for one chat, for the
/// pane's Needs you list (webviews `needsYou/asks.ts`). The pane's relay never sends `_acpmux/info`
/// (it is not in ``AcpmuxPaneMethods/requests``), so the host reads it on its own person-proven
/// connection, as the approval banners do (``AcpmuxApprovalAnswerer``), and hands the page only
/// each entry's `permissionId`, `request`, `turnId` and `groupId`: what `_acpmux/permission_pending`
/// already tells the pane's watch of every chat. It only reads; nothing is answered here.
@MainActor
public final class AgentPanePendingAsks {
    /// The app's reader; nil (a test host, the gallery) answers null, which the page treats as
    /// a chat it cannot read, so what it holds stays.
    public static var shared: AgentPanePendingAsks?

    /// Reads `_acpmux/info` for a session: its result, or nil when acpmux did not answer.
    public typealias Read = @MainActor (_ session: String) async -> [String: Any]?

    /// The keys of a pending entry the page gets.
    static let entryKeys: Set<String> = ["permissionId", "request", "turnId", "groupId"]
    /// Most entries one reply carries.
    static let maximumEntries = 64
    /// Longest session id the op takes (acpmux ids are UUIDs).
    static let maximumSession = 256

    private let read: Read

    public init(read: @escaping Read) {
        self.read = read
    }

    /// Reads through `environment`'s acpmux: one short connection per read (``AcpmuxPersonLine``).
    public convenience init(environment: AcpmuxEnvironment) {
        self.init { session in
            guard let line = await AcpmuxPersonLine.open(environment) else { return nil }
            defer { line.close() }
            return await line.call("_acpmux/info", ["sessionId": session])
        }
    }

    /// The op's answer: `{pending: [entry]}`, or null when the chat could not be read (a chat on
    /// another machine, which this Mac's acpmux does not hold; no acpmux). Throws for params that
    /// are not exactly a session id. `local`: the calling pane serves a chat on this Mac
    /// (``AgentPaneModel/readsThisMacsAcpmux``). A pane on another machine's chat
    /// (``RemoteAcpmuxWire``, scoped to that one session) answers null for every id: this read goes
    /// to this Mac's acpmux, and would show it the requests of any chat here.
    static func reply(_ params: JSONValue, op: String, local: Bool) async throws -> JSONValue {
        guard let body = params.foundationObject as? [String: Any], Set(body.keys) == ["sessionId"],
              let session = body["sessionId"] as? String, !session.isEmpty, session.utf8.count <= maximumSession
        else { throw PageError.invalidParams(op) }
        guard local, let reader = shared else { return .null }
        return await reader.pending(of: session)
    }

    /// `session`'s open requests, filtered to ``entryKeys``.
    public func pending(of session: String) async -> JSONValue {
        guard let info = await read(session), let pending = info["pending"] as? [[String: Any]] else { return .null }
        let entries = pending.prefix(Self.maximumEntries).map { entry in entry.filter { Self.entryKeys.contains($0.key) } }
        return JSONValue(foundation: ["pending": entries]) ?? .null
    }
}

extension AgentPaneModel {
    /// The pane serves a chat on this Mac: neither made for a chat on another machine
    /// (``remoteChat``) nor connected through ``RemoteAcpmuxWire``. Only such a pane reads this
    /// Mac's acpmux for Needs you (`chat.asks.pending`).
    var readsThisMacsAcpmux: Bool { !remoteChat && !transport.remoteWire }
}
