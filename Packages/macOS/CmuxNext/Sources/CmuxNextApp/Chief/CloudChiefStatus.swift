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

    nonisolated(unsafe) private static let dates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()  // ISO8601DateFormatter is thread safe.

    nonisolated static func format(_ date: Date) -> String { dates.string(from: date) }

    nonisolated static func date(_ text: Any?) -> Date? {
        guard let text = text as? String else { return nil }
        return dates.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// The state the messages show (`HomeMessage` values, oldest first or not).
    nonisolated static func status(chief: CloudChief, serverName: String, messages: [[String: Any]], now: Date) -> ChiefPlacementStatus {
        var lastReply: Date?
        var lastAsk: Date?
        for message in messages {
            guard let at = date(message["created_at"]) else { continue }
            if message["author"] as? String == chief.id {
                lastReply = max(lastReply ?? at, at)
            } else {
                lastAsk = max(lastAsk ?? at, at)
            }
        }
        var state = ChiefPlacementStatus.State.ready
        if let lastAsk, lastAsk > (lastReply ?? .distantPast) {
            state = now.timeIntervalSince(lastAsk) > quietLimit ? .notAnswering : .thinking
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
        if let conversation = chief.mainConversation {
            let reply = try await call("v1/read", ["op": "conversation.snapshot", "params": ["conversation": conversation, "tail": tail]])
            messages = ((try CloudPairingSource.okValue(reply)) as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        }
        return status(chief: chief, serverName: serverName, messages: messages, now: now())
    }
}
