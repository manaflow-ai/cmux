import CmuxHomeCore
import CmuxHomeRender
import CmuxNextSettings

/// `debug.home.delivery`: my sends the owner has not confirmed, per
/// conversation, with the reason a refused one was not delivered
/// (`HomeDeliveryReport`), so a preflight reads "invalid: attachments
/// unsupported" instead of a screenshot of the red mark.
extension DebugHome {
    static func delivery(services: AppServices) -> CmuxNextSettings.JSONValue {
        let store = services.home.homeStore
        let conversations: [CmuxNextSettings.JSONValue] = services.home.conversations.compactMap { summary in
            let rows = HomeDeliveryReport.pending(store.transcript(for: ConversationID(summary.id)))
            guard !rows.isEmpty else { return nil }
            return .object(["conversation": .string(summary.id), "sends": .array(rows.map(json))])
        }
        return .object(["online": .bool(store.isOnline), "conversations": .array(conversations)])
    }

    static func json(_ row: HomeDeliveryReport.Row) -> CmuxNextSettings.JSONValue {
        .object([
            "key": .string(row.key.rawValue),
            "state": .string(row.state),
            "reason": row.reason.map(CmuxNextSettings.JSONValue.string) ?? .null,
            "may_have_been_delivered": .bool(row.mayHaveBeenDelivered),
            "attachments": .array(row.attachments.map(CmuxNextSettings.JSONValue.string)),
            "progress": .object(row.progress.mapValues { .number($0) }),
        ])
    }
}
