import Foundation

nonisolated extension AcpmuxPaneMethods {
    /// The frame's gesture ticket, the frame without it (the daemon never sees it), and whether
    /// its `_meta` held anything besides the ticket (R1: a redeeming frame may carry nothing else,
    /// except a session/prompt's `acpmux`, whose `promptId` the held-prompt ticket is bound to).
    static func takeGestureTicket(_ text: String) -> (text: String, ticket: String?, otherMeta: Bool) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return (text, nil, false) }
        let (stripped, ticket, otherMeta) = takeGestureTicket(object)
        guard ticket != nil, let data = try? JSONSerialization.data(withJSONObject: stripped, options: [.withoutEscapingSlashes]) else {
            return (text, ticket, otherMeta)
        }
        return (String(decoding: data, as: UTF8.self), ticket, otherMeta)
    }

    /// The same on the parsed frame (the relay's one parse; an escaped key was decoded by it).
    static func takeGestureTicket(_ object: [String: Any]) -> (object: [String: Any], ticket: String?, otherMeta: Bool) {
        guard var params = object["params"] as? [String: Any], var meta = params["_meta"] as? [String: Any],
              let value = meta.removeValue(forKey: gestureTicketKey) else { return (object, nil, false) }
        let prompt = object["method"] as? String == "session/prompt"
        let otherMeta = meta.keys.contains { !(prompt && $0 == "acpmux") }
        if meta.isEmpty { params.removeValue(forKey: "_meta") } else { params["_meta"] = meta }
        var object = object
        object["params"] = params
        return (object, value as? String ?? "", otherMeta)
    }
}
