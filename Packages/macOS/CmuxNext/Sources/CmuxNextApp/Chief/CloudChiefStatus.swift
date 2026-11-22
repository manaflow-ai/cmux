import CmuxNextServer
import Foundation

/// The Server panel's view of the user's placed Chief: which paired server
/// runs it (`team.hosts.list` for the name) and a state read from the tail
/// of its main conversation (`conversation.snapshot`). Read once per panel
/// open and after an approve, never on a timer.
@MainActor
enum CloudChiefStatus {
    /// A message older than this without a Chief reply reads as `notAnswering`.
    nonisolated static let quietLimit: TimeInterval = 120
    /// How many messages the panel reads.
    nonisolated static let tail = 20

    /// RFC 3339 with milliseconds, as the owners write `created_at` (a Sendable value type).
    nonisolated private static let millis = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    nonisolated private static let seconds = Date.ISO8601FormatStyle()

    nonisolated static func format(_ date: Date) -> String { date.formatted(millis) }

    nonisolated static func date(_ text: Any?) -> Date? {
        guard let text = text as? String else { return nil }
        return (try? millis.parse(text)) ?? (try? seconds.parse(text))
    }

    /// The state the messages show (`HomeMessage` values, oldest first or not).
    /// `chiefReadSeq`: the Chief's read cursor in its main conversation
    /// (`read_cursors[chief]`), nil when unknown.
    nonisolated static func status(chief: CloudChief, serverName: String, messages: [[String: Any]], chiefReadSeq: Int? = nil,
                                   now: Date) -> ChiefPlacementStatus {
        var lastReply: Date?
        var lastAsk: (at: Date, seq: Int?)?
        for message in messages {
            guard let at = date(message["created_at"]) else { continue }
            if message["author"] as? String == chief.id {
                lastReply = max(lastReply ?? at, at)
            } else if lastAsk.map({ at > $0.at }) ?? true {
                lastAsk = (at, (message["seq"] as? NSNumber)?.intValue)
            }
        }
        var state = ChiefPlacementStatus.State.ready
        if let lastAsk, lastAsk.at > (lastReply ?? .distantPast) {
            // A message the brain read is being worked on, however long the
            // turn runs; past the quiet limit only an unread one is silence.
            let read = lastAsk.seq.flatMap { seq in chiefReadSeq.map { $0 >= seq } } ?? false
            state = !read && now.timeIntervalSince(lastAsk.at) > quietLimit ? .notAnswering : .thinking
        }
        let name = chief.displayName.isEmpty ? HomeStrings.chiefName : chief.displayName
        return ChiefPlacementStatus(serverName: serverName, chiefName: name, state: state, lastReply: lastReply)
    }

    /// The placed Chief's status, or nil when no chief is placed on a server.
    static func read(call: CloudChiefs.Call, now: @escaping () -> Date = Date.init) async throws -> ChiefPlacementStatus? {
        guard let chief = CloudChiefs.placed(in: try await CloudChiefs.list(call: call)), let place = chief.brainPlace else { return nil }
        var serverName = place.host
        if let hosts = (try? CloudPairingSource.okValue(try await call("v1/read", ["op": "team.hosts.list", "params": [String: Any]()]))) as? [String: Any],
           let host = (hosts["hosts"] as? [[String: Any]])?.first(where: { $0["id"] as? String == place.host }),
           let name = host["name"] as? String {
            serverName = name
        }
        var messages: [[String: Any]] = []
        var chiefReadSeq: Int?
        if let conversation = chief.mainConversation {
            let reply = try await call("v1/read", ["op": "conversation.snapshot", "params": ["conversation": conversation, "tail": tail]])
            let snapshot = (try CloudPairingSource.okValue(reply)) as? [String: Any]
            messages = snapshot?["messages"] as? [[String: Any]] ?? []
            let cursors = (snapshot?["conversation"] as? [String: Any])?["read_cursors"] as? [String: Any]
            chiefReadSeq = (cursors?[chief.id] as? NSNumber)?.intValue
        }
        return status(chief: chief, serverName: serverName, messages: messages, chiefReadSeq: chiefReadSeq, now: now())
    }
}
