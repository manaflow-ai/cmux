import CmuxNextSettings
import Foundation

/// Keeps an open Share dialog current (webviews share/shareChanges.ts). The daemon's
/// `agent-session-share-changed` (a request, a role change, a removal, a join, made anywhere) reaches
/// each page whose Share dialog read that chat's shares, and the dialog reads them again. Before
/// this, the dialog read only on open and after its own steps, so a request that came in while it
/// was open showed only after it was closed and opened again.
/// App-wide like ``AgentReplyPullRequests``: the App feeds ``changed(_:)`` from its daemon's events.
@MainActor
public final class AgentPaneShareChanges {
    public static let shared = AgentPaneShareChanges()

    /// The composition root uses ``shared``; a test may use its own.
    public init() {}

    /// Pages that read a chat's shares (its Share dialog opened), held weakly.
    private let views = NSHashTable<AgentPaneView>.weakObjects()

    /// `view`'s page read its chat's shares: it hears that chat's changes from now on.
    func watch(_ view: AgentPaneView) { views.add(view) }

    /// The shares of the chat on acpmux session `session` changed: each watching page that shows it
    /// hears `shareChanged`. A page showing another chat by now hears nothing.
    public func changed(_ session: String) {
        guard !session.isEmpty else { return }
        for view in views.allObjects where view.model.header?.showsChat(session) == true {
            view.deliver([Self.event(session)], scripts: [Self.script(session)])
        }
    }

    static func event(_ session: String) -> AgentPageEvent {
        AgentPageEvent(kind: "shareChanged", value: .string(session))
    }

    /// The legacy host's script for the same push (`applyShareChanged`, paneSnapshot.ts).
    static func script(_ session: String) -> String {
        "window.cmuxAcpmuxBridge?.applyShareChanged?.(\(JSONValue.string(session).compactText));"
    }
}
