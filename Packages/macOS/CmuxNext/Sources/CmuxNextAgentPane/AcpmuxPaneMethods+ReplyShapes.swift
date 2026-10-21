import Foundation

/// The replies the relay filters itself (ad349), of ``AcpmuxPaneMethods``: read-only requests
/// whose reply reaches the pane cut to the fields it renders.
nonisolated extension AcpmuxPaneMethods {
    /// The shape of a reply the relay filters itself, without relying on the daemon's redaction.
    public nonisolated indirect enum ReplyShape: Sendable {
        case string
        case object([String: ReplyShape])
        case list(ReplyShape)
        /// Only the scheme of the URL in the sibling field `source` (`ssh`, `ws`, `wss`), so the
        /// page learns a peer's transport without its URL (which can carry a user or a token).
        case scheme(from: String)
    }

    /// The URL schemes a `.scheme` field may report; any other scheme is dropped.
    static let reportedSchemes: Set<String> = ["ssh", "ws", "wss"]

    /// Replies filtered to the fields the pane renders; everything else is dropped, at every depth.
    /// `_acpmux/status`: the pane reads only `peers[].name` and each peer's `transport`, the
    /// scheme of its `url` (direct.ts, after initialize; environments.ts peerKindsFromStatus).
    public static let replyShapes: [String: ReplyShape] = [
        "_acpmux/status": .object([
            "peers": .list(.object(["name": .string, "transport": .scheme(from: "url")])),
        ]),
    ]

    /// `value` cut to `shape`: nil when it does not fit (a list keeps only the items that fit).
    static func filtered(_ value: Any, to shape: ReplyShape) -> Any? {
        switch shape {
        case .string:
            return value as? String
        case .scheme:
            guard let scheme = (value as? String).flatMap({ URLComponents(string: $0)?.scheme?.lowercased() }),
                  reportedSchemes.contains(scheme) else { return nil }
            return scheme
        case .list(let item):
            return (value as? [Any])?.compactMap { filtered($0, to: item) }
        case .object(let fields):
            guard let object = value as? [String: Any] else { return nil }
            let kept = fields.compactMap { key, field -> (String, Any)? in
                let source: String
                if case .scheme(let from) = field { source = from } else { source = key }
                return object[source].flatMap { filtered($0, to: field) }.map { (key, $0) }
            }
            // An object with none of its fields is dropped (a peer with no name renders nothing).
            return kept.isEmpty ? nil : Dictionary(uniqueKeysWithValues: kept)
        }
    }

    /// A reply to a filtered request, rebuilt with the page's id (raw JSON) and its filtered
    /// result. An error keeps only its code and message.
    static func filteredReply(_ object: [String: Any], shape: ReplyShape, pageID: String) -> String {
        let id = (try? JSONSerialization.jsonObject(with: Data(pageID.utf8), options: [.fragmentsAllowed])) ?? NSNull()
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let error = object["error"] as? [String: Any] {
            reply["error"] = ["code": error["code"] as? Int ?? -32603, "message": error["message"] as? String ?? ""]
        } else {
            reply["result"] = object["result"].flatMap { filtered($0, to: shape) } ?? [String: Any]()
        }
        let data = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
