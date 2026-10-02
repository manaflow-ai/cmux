import Foundation

/// MessagesLab message JSON (shared/MODEL.md) to ``HomeMessage``. Parts the
/// renderer does not draw become fallback parts named after their content.
nonisolated enum HomeSQLiteDecoding {
    static func message(_ object: [String: Any], seq: Int, dates: ISO8601DateFormatter) -> HomeMessage? {
        guard let id = object["id"] as? String, let author = object["senderId"] as? String else { return nil }
        let createdAt = (object["sentAt"] as? String).flatMap(dates.date(from:)) ?? Date(timeIntervalSince1970: 0)
        let parts = (object["parts"] as? [[String: Any]] ?? []).map(part)
        let reactions: [HomeReaction] = (object["reactions"] as? [[String: Any]] ?? []).compactMap { reaction in
            guard let sender = reaction["senderId"] as? String, let kind = reaction["kind"] as? [String: Any] else { return nil }
            let name = kind["tapback"] as? String ?? kind["emoji"] as? String ?? "like"
            return HomeReaction(authorID: sender, partIndex: reaction["partIndex"] as? Int ?? 0, kind: name)
        }
        let retracted = (object["retractedAt"] as? String).flatMap(dates.date(from:))
        let edited = (object["edits"] as? [[String: Any]])?.last.flatMap { ($0["at"] as? String).flatMap(dates.date(from:)) }
        let delivery: HomeDelivery = object["status"] == nil ? .none : .sent
        let replyTo = (object["replyTo"] as? [String: Any])?["messageId"] as? String
        return HomeMessage(id: id, seq: seq, clientMsgID: id, authorID: author, parts: retracted == nil ? parts : [],
                           replyTo: replyTo, createdAt: createdAt, delivery: delivery, reactions: reactions,
                           editedAt: edited, retractedAt: retracted)
    }

    static func part(_ object: [String: Any]) -> HomePart {
        switch object["type"] as? String {
        case "text":
            let text = object["text"] as? String ?? ""
            let mentions: [HomeMention] = (object["runs"] as? [[String: Any]] ?? []).compactMap { run in
                guard let who = run["mention"] as? String, let start = run["start"] as? Int,
                      let length = run["length"] as? Int else { return nil }
                return HomeMention(start: start, length: length, participantID: who)
            }
            return .text(text, mentions: mentions)
        case "link":
            return .fallback(object["title"] as? String ?? object["url"] as? String ?? "")
        case "attachment":
            let attachment = object["attachment"] as? [String: Any]
            return .fallback(attachment?["fileName"] as? String ?? "")
        case "location":
            return .fallback(object["title"] as? String ?? "\(object["latitude"] ?? ""), \(object["longitude"] ?? "")")
        default:
            return .fallback(object["type"] as? String ?? "")
        }
    }
}
