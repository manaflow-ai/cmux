import CmuxNextSettings
import Foundation

/// Carries the daemon's `agent-session-share-changed` to each agent pane whose page read a chat's shares
/// (`shareOp` `state`), so an open Share dialog re-reads its chat on an access request, a role change or a removal made
/// elsewhere (ask-fe19418926). Only the chat id goes with it; the page reads the state itself.
public enum AgentPaneShareChanges {
    static var name: Notification.Name { Notification.Name("cmux.agentPane.shareChanged") }

    /// The daemon reported `session`'s shares changed.
    @MainActor public static func changed(_ session: String) {
        guard !session.isEmpty else { return }
        NotificationCenter.default.post(name: name, object: session)
    }

    /// Follows changes for `view` until the view goes; the caller keeps the token and removes it.
    @MainActor static func watch(_ view: AgentPaneView) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak view] note in
            guard let session = note.object as? String else { return }
            MainActor.assumeIsolated {
                guard let view, view.model.header?.showsChat(session) == true else { return }
                view.deliver([event(session)], scripts: [script(session)])
            }
        }
    }

    static func event(_ session: String) -> AgentPageEvent { AgentPageEvent(kind: "shareChanged", value: .string(session)) }

    static func script(_ session: String) -> String {
        "window.cmuxAcpmuxBridge?.applyShareChanged?.(\(JSONValue.string(session).compactText));"
    }
}
