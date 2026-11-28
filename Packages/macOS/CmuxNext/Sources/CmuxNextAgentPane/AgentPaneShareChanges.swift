import CmuxNextSettings
import Foundation

/// Carries the daemon's `agent-session-share-changed` to each agent pane whose page read a chat's shares
/// (`shareOp` `state`), so an open Share dialog re-reads its chat on an access request, a role change or a removal made
/// elsewhere (ask-fe19418926). The app holds one (``AgentPaneShared/shareChanges``); only the chat id goes to the
/// page, which reads the state itself.
@MainActor
public final class AgentPaneShareChanges {
    private let views = NSHashTable<AgentPaneView>.weakObjects()

    public init() {}

    /// `view`'s page read a chat's shares: it hears that chat's changes from now on.
    func watch(_ view: AgentPaneView) { views.add(view) }

    /// The daemon reported `session`'s shares changed: each watching pane that still shows it re-reads.
    public func changed(_ session: String) {
        guard !session.isEmpty else { return }
        for view in views.allObjects where view.model.header?.showsChat(session) == true {
            view.deliver([Self.event(session)], scripts: [Self.script(session)])
        }
    }

    static func event(_ session: String) -> AgentPageEvent { AgentPageEvent(kind: "shareChanged", value: .string(session)) }

    static func script(_ session: String) -> String {
        "window.cmuxAcpmuxBridge?.applyShareChanged?.(\(JSONValue.string(session).compactText));"
    }
}
