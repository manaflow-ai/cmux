public import Foundation

/// The message being acted on by a message action (`cmux.chat.action/1`): its transcript row id,
/// `user` or `assistant`, its text (a reply's Markdown) and its chat.
public struct AppChatMessage: Equatable, Sendable {
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

/// Message actions (`cmux.chat.action/1`): the rows the installed extensions add to a message's
/// menu. The daemon decides which there are and runs the picked one (cmux-tui-core
/// `apps/chat_actions.rs`); the client only asks and passes the pick on.
extension AppsClient {
    /// The message actions for a message of `role` (`user`, `assistant`; nil: every role), as the
    /// daemon answers `apps.chat_actions.list`: `{actions: [{app, extension, id, title, symbol?}]}`.
    public func chatActions(role: String?) async throws(AppsClientError) -> AppJSON {
        if case .unavailable(let reason) = availability { throw .unavailable(reason) }
        let args: AppJSON = role.map { .object(["role": .string($0)]) } ?? .object([:])
        do throws(AppsTransportError) { return try await transport.storeCall("apps.chat_actions.list", args: args) }
        catch { throw .refused(error) }
    }

    /// Runs `app`'s message action `action` on `message`, picked by the person in the message's
    /// menu. Returns the op's result.
    @discardableResult
    public func runChatAction(app: String, action: String, message: AppChatMessage) async throws(AppsClientError) -> AppJSON {
        if case .unavailable(let reason) = availability { throw .unavailable(reason) }
        do throws(AppsTransportError) { return try await transport.chatAction(app: app, action: action, message: message, origin: .user) }
        catch { throw .refused(error) }
    }
}
