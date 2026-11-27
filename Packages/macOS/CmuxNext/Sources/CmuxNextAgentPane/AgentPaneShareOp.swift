import Foundation

/// The agent chat's Share dialog (`share.op {op, ...}`, webviews agent-session/acpmux/share): one op on
/// THIS pane's chat, never a chat the page names. The app forwards it to the daemon's share requests
/// (``AgentPaneModel/onShareOp``); the pane only decodes it and gates the ops that widen who sees
/// the chat on a real gesture.
public nonisolated enum AgentPaneShareOp: Equatable, Sendable {
    /// `{op:"state"}`: this chat's shares, with their guests and invitees.
    case state
    /// `{op:"link", role}`: a new link to this chat (`role` `view` or `talk`, `view` when absent).
    case link(role: String)
    /// `{op:"invite", account, role}`: the account may join this chat after signing in.
    case invite(account: String, role: String)
    /// `{op:"uninvite", account}`: the account leaves every share of this chat.
    case uninvite(account: String)
    /// `{op:"revoke", shareId}`: one share of this chat stops working.
    case revoke(shareId: String)
    /// `{op:"manage"}`: Settings at its Shared links card.
    case manage

    static let roles: Set<String> = ["view", "talk"]

    /// A link or an invite shows the chat to someone new: only the person's click makes one.
    public var needsGesture: Bool {
        switch self {
        case .link, .invite: true
        case .state, .uninvite, .revoke, .manage: false
        }
    }

    /// Nil for an unknown op or a malformed field.
    init?(params: [String: Any]?) {
        func text(_ key: String, limit: Int) -> String? {
            guard let raw = params?[key] as? String else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty || value.utf8.count > limit ? nil : value
        }
        func role(_ fallback: String?) -> String? {
            guard params?["role"] != nil else { return fallback }
            return (params?["role"] as? String).map { $0.lowercased() }.flatMap { Self.roles.contains($0) ? $0 : nil }
        }
        switch params?["op"] as? String {
        case "state": self = .state
        case "manage": self = .manage
        case "link":
            guard let role = role("view") else { return nil }
            self = .link(role: role)
        case "invite":
            guard let account = text("account", limit: 320), let role = role(nil) else { return nil }
            self = .invite(account: account, role: role)
        case "uninvite":
            guard let account = text("account", limit: 320) else { return nil }
            self = .uninvite(account: account)
        case "revoke":
            guard let shareId = text("shareId", limit: 128) else { return nil }
            self = .revoke(shareId: shareId)
        default: return nil
        }
    }
}

/// What the app answers a ``AgentPaneShareOp``: the reply's value, or a refusal with its code (the
/// daemon's `share.*`, or `unavailable`) and a sentence for the person.
public enum AgentPaneShareReply {
    case value([String: Any])
    case refused(code: String, message: String)
}

extension AgentPaneModel {
    /// One Share dialog op on this pane's chat. A link or an invite needs the page host's
    /// authenticated click (`userGesture`) or the legacy bridge's gesture credit, so page script
    /// alone never widens who sees the chat.
    func shareOp(_ op: AgentPaneShareOp, session: String? = nil, userGesture: Bool) async -> [String: Any] {
        guard let onShareOp else { return Self.unsupported("share.op") }
        // Bound to the chat the dialog opened on: a tab that shows another chat by now does nothing
        // (checked before the gesture, so a refused op spends no click).
        if let session, header?.showsChat(session) != true {
            return AgentPaneReply.failure(code: "unavailable", message: "This chat is no longer shown.")
        }
        if op.needsGesture, !(userGesture || transport.gestures.consume()) {
            return AgentPaneReply.failure(code: "gesture_required", message: Self.transportFailedMessage)
        }
        switch await onShareOp(op, session) {
        case .value(let value)?: return AgentPaneReply.success(value)
        case .refused(let code, let message)?: return AgentPaneReply.failure(code: code, message: message)
        // The app is closing this tab's page.
        case nil: return Self.unsupported("share.op")
        }
    }
}
