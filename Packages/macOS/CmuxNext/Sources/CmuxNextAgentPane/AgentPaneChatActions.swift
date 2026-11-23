import AppKit
import CmuxNextApps

/// The installed extensions' message actions (`cmux.chat.action/1`) for the message under the
/// pointer, as the page reports them with it (webviews conversation/chatActions.ts): the daemon
/// listed them (`apps.chat_actions.list`), the menu draws them, and a pick goes back to the daemon
/// (`apps-chat-action`), which checks the app lists it and runs its op.
struct AgentPaneChatActions: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        let app: String
        let id: String
        let title: String
        let symbol: String?
    }

    let message: AppChatMessage
    let rows: [Row]

    /// The report's `chatActions` (`{message: {id, role, text, session?}, rows: [{app, id, title,
    /// symbol?}]}`); nil without a message or a row, so the menu is as it is with no extensions.
    init?(report body: Any?) {
        guard let object = body as? [String: Any], let message = object["message"] as? [String: Any],
              let id = message["id"] as? String, !id.isEmpty,
              let role = message["role"] as? String, !role.isEmpty,
              let text = message["text"] as? String else { return nil }
        let rows = (object["rows"] as? [Any] ?? []).compactMap { entry -> Row? in
            guard let row = entry as? [String: Any], let app = row["app"] as? String, !app.isEmpty,
                  let id = row["id"] as? String, !id.isEmpty,
                  let title = row["title"] as? String, !title.isEmpty else { return nil }
            return Row(app: app, id: id, title: title, symbol: (row["symbol"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        guard !rows.isEmpty else { return nil }
        self.message = AppChatMessage(id: id, role: role, text: text,
                                      session: (message["session"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        self.rows = rows
    }

    init(message: AppChatMessage, rows: [Row]) {
        self.message = message
        self.rows = rows
    }
}

@MainActor
extension AgentPaneChatActions {
    /// One menu row per action, with its symbol (a puzzle piece when it names none).
    func items(run: @escaping (String, String, AppChatMessage) -> Void) -> [NSMenuItem] {
        rows.map { row in
            AgentPaneMenuAction.item(row.title, symbol: row.symbol ?? "puzzlepiece.extension") { run(row.app, row.id, message) }
        }
    }
}
