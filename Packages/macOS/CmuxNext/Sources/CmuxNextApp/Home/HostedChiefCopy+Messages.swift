import CmuxNextDaemon
import Foundation

extension HostedChiefCopy {
    /// The local Chief conversation's messages as `conversation.import`
    /// messages of the Hosted Chief's main conversation (home-core import.ts):
    /// only the local user's and the local Chief's messages (a cloud Chief
    /// conversation has those two participants), the local ids mapped to the
    /// account's (`user_local` to `user`, `agent_mux` to `chief`, exact string
    /// values only, as optchat-chief's cloud idmap), dense seqs from 1, text and
    /// work parts only (an attachment becomes a short text), times in the
    /// owner's form and never going back, and references to a dropped message
    /// or part removed.
    nonisolated static func importMessages(_ local: [ConversationMessage], user: String, chief: String, localChief: String,
                                           now: Date = Date()) -> [[String: Any]] {
        let ids = [ConversationParticipant.localUserID: user, localChief: chief]
        let encoder = JSONEncoder()
        var out: [[String: Any]] = []
        var kept: [String: (seq: Int, parts: Int, root: Bool)] = [:]
        var keys = Set<String>()
        var previous = Date.distantPast
        let latest = now.addingTimeInterval(240)
        for message in local.sorted(by: { $0.seq < $1.seq }) where ids[message.author] != nil {
            guard let data = try? encoder.encode(message),
                  var raw = (try? JSONSerialization.jsonObject(with: data)).map({ mapIDs($0, ids) }) as? [String: Any] else { continue }
            // The owner's id form (msg_ and 1 to 40 letters or digits); another local id keeps its letters and digits.
            let plain = String(String.UnicodeScalarView(message.id.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }))
            let messageID = message.id.range(of: #"^msg_[A-Za-z0-9]{1,40}$"#, options: .regularExpression) != nil ? message.id : "msg_" + String(plain.prefix(40))
            guard messageID.count > 4, kept[messageID] == nil else { continue }
            let author = raw["author"] as? String ?? ""
            // Times: the owner's RFC 3339 form with milliseconds, never before the previous message or in the future.
            let created = min(max(parse(message.createdAt) ?? previous, previous), latest)
            previous = created
            let retracted = message.retractedAt.map { stamp(min(max(parse($0) ?? created, created), latest)) }
            var parts = (raw["parts"] as? [[String: Any]] ?? []).filter { part in
                switch part["type"] as? String {
                case "text": return !((part["text"] as? String) ?? "").isEmpty
                case "work": return true
                default: return false
                }
            }
            if retracted != nil { parts = [] } else if parts.isEmpty { parts = [["type": "text", "text": "[attachment]"]] }
            parts = Array(parts.prefix(16))
            let seq = out.count + 1
            var key = message.clientMsgID
            if key.isEmpty || key.count > 128 || key.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value > 0x7e }) || keys.contains("\(author):\(key)") {
                key = messageID
            }
            keys.insert("\(author):\(key)")
            var next: [String: Any] = ["id": messageID, "seq": seq, "client_msg_id": key, "author": author, "parts": parts, "created_at": stamp(created)]
            if let retracted { next["retracted_at"] = retracted }
            if let edited = message.editedAt, retracted == nil { next["edited_at"] = stamp(min(max(parse(edited) ?? created, created), latest)) }
            if let reply = raw["reply_to"] as? [String: Any], let target = reply["message_id"] as? String, let index = reply["part_index"] as? Int,
               let found = kept[target], index < found.parts {
                next["reply_to"] = ["message_id": target, "part_index": index]
            }
            if let root = message.threadRoot, kept[root]?.root == true { next["thread_root"] = root }
            let reactions = (raw["reactions"] as? [[String: Any]] ?? []).filter { reaction in
                guard let by = reaction["author"] as? String, ids.values.contains(by), let index = reaction["part_index"] as? Int,
                      index < parts.count, let at = reaction["at"] as? String else { return false }
                return parse(at) != nil
            }.map { reaction -> [String: Any] in
                var reaction = reaction
                let at = parse(reaction["at"] as? String ?? "") ?? created
                reaction["at"] = stamp(min(max(at, created), latest))
                return reaction
            }
            if retracted == nil, !reactions.isEmpty { next["reactions"] = reactions }
            raw = next
            kept[messageID] = (seq, parts.count, next["thread_root"] == nil)
            out.append(raw)
        }
        return out
    }

    /// Replaces exact string values and object keys found in `ids` (never text that only contains one).
    nonisolated private static func mapIDs(_ value: Any, _ ids: [String: String]) -> Any {
        switch value {
        case let text as String: return ids[text] ?? text
        case let list as [Any]: return list.map { mapIDs($0, ids) }
        case let object as [String: Any]:
            return Dictionary(uniqueKeysWithValues: object.map { (ids[$0.key] ?? $0.key, mapIDs($0.value, ids)) })
        default: return value
        }
    }

    nonisolated private static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    /// `2026-10-19T07:00:00.000Z` (home-core ids.ts parseRfc3339Millis).
    nonisolated static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter.string(from: date)
    }
}
