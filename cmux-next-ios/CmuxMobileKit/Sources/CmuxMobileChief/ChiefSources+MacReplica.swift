import CmuxConversationCore
import Foundation

/// The Mac Chief with the Mac offline (cmux-prompts logs/iphone-chief-DESIGN.md, a450):
/// its cloud copy, and the one-tap hand-off of a message to the Cloud Chief.
extension ChiefSources {
    /// Why the Mac Chief runs on its cloud copy: shown on Chief's bar.
    public static var macOfflineReason: String {
        String(localized: "Your Mac is offline. Messages wait in the cloud and reach Chief when your Mac is back.")
    }

    /// The cloud copy of the Mac Chief on the Mac named `macName`, or nil when
    /// the account is signed out or this Mac publishes no copy (Settings >
    /// Phone Access > Cloud copy, off by default on the Mac).
    public func macReplica(named macName: String?) async -> ChiefReplicaBackend? {
        guard let http, let userID else { return nil }
        guard let value = try? await Self.read(http, "team.hosts.list", [:]),
              let hosts = value["hosts"] as? [[String: Any]],
              let host = Self.pickHost(hosts, userID: userID, macName: macName) else { return nil }
        return ChiefReplicaBackend(http: http, host: host)
    }

    /// The host to read: the account's own macOS host named `macName`, else
    /// its only macOS host; nil when that is ambiguous or there is none.
    nonisolated static func pickHost(_ hosts: [[String: Any]], userID: String, macName: String?) -> String? {
        let mine = hosts.filter { $0["owner_user"] as? String == userID && ($0["platform"] as? String ?? "macos") == "macos" }
        if let macName, let named = mine.first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(macName) == .orderedSame }) {
            return named["id"] as? String
        }
        return mine.count == 1 ? mine[0]["id"] as? String : nil
    }

    /// The text the Cloud Chief gets for a hand-off: the request, then the
    /// Mac Chief's newest messages as context, oldest first.
    nonisolated static func handOffText(_ request: String, context: [ConversationMessage], meID: String) -> String {
        let lines = context.map { message in
            let who = message.senderID == meID ? "Me" : "Mac Chief"
            return "\(who): \(message.text.replacingOccurrences(of: "\n", with: " "))"
        }
        let header = "My Mac is offline, so I'm asking you instead of my Mac Chief."
        guard !lines.isEmpty else { return "\(header)\n\n\(request)" }
        return "\(header)\n\n\(request)\n\nRecent messages with my Mac Chief, oldest first:\n" + lines.joined(separator: "\n")
    }

    /// Hands `request` to the Cloud Chief with the Mac Chief's last 20
    /// messages (``handOffText(_:context:meID:)``), through the Cloud Chief's
    /// own session (its outbox keeps it until the Cloud Chief answers).
    public func askCloudChief(_ request: String) async {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let context: [ConversationMessage]
        if let replica = mac.backend as? ChiefReplicaBackend {
            context = await replica.recentMessages(20)
        } else {
            context = Array(mac.store.messages.suffix(20))
        }
        cloud.send(ConversationComposeMessage(text: Self.handOffText(trimmed, context: context, meID: ChiefIdentity.standard.meID)))
    }

    nonisolated static func read(_ http: ChiefCloudHTTP, _ op: String, _ params: [String: Any]) async throws -> [String: Any] {
        let body = try ChiefCloudHTTP.json(["op": op, "params": params])
        let reply = try await http.send("POST", "/v1/read", body: body)
        return try ChiefCloudHTTP.value(reply) as? [String: Any] ?? [:]
    }
}
