import Foundation

/// The replies the relay filters itself (ad349), of ``AcpmuxPaneMethods``: read-only requests
/// whose reply reaches the pane cut to the fields it renders.
nonisolated extension AcpmuxPaneMethods {
    /// The shape of a reply the relay filters itself, without relying on the daemon's redaction.
    public nonisolated indirect enum ReplyShape: Sendable {
        case string
        case object([String: ReplyShape])
        case list(ReplyShape)
    }

    /// Replies filtered to the fields the pane renders; everything else is dropped, at every depth.
    /// `_acpmux/status`: the pane reads only `peers[].name` (direct.ts, after initialize).
    public static let replyShapes: [String: ReplyShape] = [
        "_acpmux/status": .object(["peers": .list(.object(["name": .string]))]),
    ]

    /// `value` cut to `shape`: nil when it does not fit (a list keeps only the items that fit).
    static func filtered(_ value: Any, to shape: ReplyShape) -> Any? {
        switch shape {
        case .string:
            return value as? String
        case .list(let item):
            return (value as? [Any])?.compactMap { filtered($0, to: item) }
        case .object(let fields):
            guard let object = value as? [String: Any] else { return nil }
            let kept = fields.compactMap { key, field in object[key].flatMap { filtered($0, to: field) }.map { (key, $0) } }
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
