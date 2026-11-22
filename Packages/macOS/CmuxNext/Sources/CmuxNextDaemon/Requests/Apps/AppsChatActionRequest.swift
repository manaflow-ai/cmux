import Foundation

/// `apps-chat-action`: a message action (`cmux.chat.action/1`) the person picked in a message's
/// menu. The daemon checks that `app` lists `action` for the message's role and runs the row's op
/// with `{action, message}` on the `apps-run` path (cmux-tui-core `apps/chat_actions.rs`).
public struct AppsChatActionRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-chat-action"

    /// The message the menu opened on: its transcript row id, `user` or `assistant`, its text
    /// (a reply's Markdown) and its chat.
    public struct Message: Codable, Equatable, Sendable {
        public var id: String
        public var role: String
        public var text: String
        public var session: String?

        public init(id: String, role: String, text: String, session: String? = nil) {
            self.id = id
            self.role = role
            self.text = text
            self.session = session
        }
    }

    public var app: String
    public var action: String
    public var message: Message
    /// `user` needs the verified cmux app connection, as for `apps-run`.
    public var origin: AppsRunRequest.Origin

    public init(app: String, action: String, message: Message, origin: AppsRunRequest.Origin) {
        self.app = app
        self.action = action
        self.message = message
        self.origin = origin
    }
}
