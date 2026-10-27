import CmuxNextCompat
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
        // Kept messages by their LOCAL id: the new id, and each kept part's old index -> new index.
        var kept: [String: (id: String, parts: [Int: Int], root: Bool)] = [:]
        var used = Set<String>()
        var keys = Set<String>()
        // A time that does not parse takes the previous parseable one, else now (never a fixed past date).
        var previous: Date?
        let latest = now.addingTimeInterval(240)
        for message in local.sorted(by: { $0.seq < $1.seq }) where ids[message.author] != nil {
            guard let data = try? encoder.encode(message),
                  let raw = (try? JSONSerialization.blockingJSONObject(with: data)).map({ mapIDs($0, ids) }) as? [String: Any] else { continue }
            // The owner's id form (msg_ and 1 to 40 letters or digits); another local id keeps its letters and digits.
            let plain = String(String.UnicodeScalarView(message.id.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }))
            let messageID = message.id.range(of: #"^msg_[A-Za-z0-9]{1,40}$"#, options: .regularExpression) != nil ? message.id : "msg_" + String(plain.prefix(40))
            guard messageID.count > 4, !used.contains(messageID), kept[message.id] == nil else { continue }
            let author = raw["author"] as? String ?? ""
            // Times: the owner's RFC 3339 form with milliseconds, never before the previous message or in the future.
            let parsed = parse(message.createdAt) ?? previous ?? now
            let created = min(max(parsed, previous ?? parsed), latest)
            previous = created
            let retracted = message.retractedAt.map { stamp(min(max(parse($0) ?? created, created), latest)) }
            var parts: [[String: Any]] = []
            var partMap: [Int: Int] = [:]
            if retracted == nil {
                for (index, part) in (raw["parts"] as? [[String: Any]] ?? []).enumerated() where parts.count < 16 {
                    let keep = switch part["type"] as? String {
                    case "text": !((part["text"] as? String) ?? "").isEmpty
                    case "work": true
                    default: false
                    }
                    if keep {
                        partMap[index] = parts.count
                        parts.append(part)
                    }
                }
                if parts.isEmpty { parts = [["type": "text", "text": "[attachment]"]] }
            }
            let seq = out.count + 1
            var key = message.clientMsgID
            if key.isEmpty || key.count > 128 || key.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value > 0x7e }) || keys.contains("\(author):\(key)") {
                key = messageID
            }
            keys.insert("\(author):\(key)")
            var next: [String: Any] = ["id": messageID, "seq": seq, "client_msg_id": key, "author": author, "parts": parts, "created_at": stamp(created)]
            if let retracted { next["retracted_at"] = retracted }
            if let edited = message.editedAt, retracted == nil { next["edited_at"] = stamp(min(max(parse(edited) ?? created, created), latest)) }
            // A reply or thread whose message or part was dropped loses the reference.
            if let reply = message.replyTo, let found = kept[reply.messageID], let index = found.parts[reply.partIndex] {
                next["reply_to"] = ["message_id": found.id, "part_index": index]
            }
            if let root = message.threadRoot, let found = kept[root], found.root { next["thread_root"] = found.id }
            let reactions = retracted != nil ? [] : (raw["reactions"] as? [[String: Any]] ?? []).compactMap { reaction -> [String: Any]? in
                guard let by = reaction["author"] as? String, ids.values.contains(by), let old = reaction["part_index"] as? Int,
                      let index = partMap[old], let at = (reaction["at"] as? String).flatMap(parse) else { return nil }
                var reaction = reaction
                reaction["part_index"] = index
                reaction["at"] = stamp(min(max(at, created), latest))
                return reaction
            }
            if !reactions.isEmpty { next["reactions"] = reactions }
            kept[message.id] = (messageID, partMap, next["thread_root"] == nil)
            used.insert(messageID)
            out.append(next)
        }
        return out
    }

    /// Replaces exact string values and object keys found in `ids` (never text that only contains one).
    /// A renamed key that lands on a key the object already has replaces it: the renamed entry is the copied one.
    nonisolated private static func mapIDs(_ value: Any, _ ids: [String: String]) -> Any {
        switch value {
        case let text as String: return ids[text] ?? text
        case let list as [Any]: return list.map { mapIDs($0, ids) }
        case let object as [String: Any]:
            var mapped: [String: Any] = [:]
            for (key, item) in object where ids[key] == nil { mapped[key] = mapIDs(item, ids) }
            for (key, item) in object { if let renamed = ids[key] { mapped[renamed] = mapIDs(item, ids) } }
            return mapped
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
