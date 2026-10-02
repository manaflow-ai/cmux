import CmuxNextDaemon
import CmuxNextSettings

/// `debug.home`: Home per window and the conversation projection
/// (plans/cmux-next/home.md), for automation on a never-key test window.
@MainActor
enum DebugHome {
    static func report(services: AppServices) -> CmuxNextSettings.JSONValue {
        let home = services.home
        let windows: [CmuxNextSettings.JSONValue] = services.windows.controllers.map { controller in
            .object([
                "window": .string(controller.state.id),
                "shows_home": .bool(controller.state.showsHome),
                "home_view_installed": .bool(controller.home.view?.superview != nil),
                "workspace": controller.state.workspaceID.map(CmuxNextSettings.JSONValue.string) ?? .null,
            ])
        }
        let conversations: [CmuxNextSettings.JSONValue] = home.conversations.map { summary in
            var row: [String: CmuxNextSettings.JSONValue] = [
                "id": .string(summary.id), "title": .string(summary.title), "last_seq": .number(Double(summary.lastSeq)),
                "rev": .number(Double(summary.rev)),
                "participants": .array(summary.participants.map { .string($0.id) }),
            ]
            if let session = home.sessions[summary.id] {
                row["mirror_rev"] = session.mirror.map { .number(Double($0.rev)) } ?? .null
                row["pending"] = .array(session.log.entries.map { entry in
                    .object(["client_msg_id": .string(entry.clientMsgID), "state": .string(String(describing: entry.state))])
                })
                row["typing"] = .array(session.typing.sorted().map(CmuxNextSettings.JSONValue.string))
                row["tail"] = .array((session.mirror?.tail.suffix(10) ?? []).map { message in
                    .object(["seq": .number(Double(message.seq)), "author": .string(message.author),
                             "text": .string(message.parts.map(\.plainText).joined(separator: "\n"))])
                })
            }
            return .object(row)
        }
        return .object(["available": .bool(home.isAvailable), "windows": .array(windows), "conversations": .array(conversations)])
    }
}
