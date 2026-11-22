import CmuxNextActions
import Foundation
import CmuxNextRemoteView

/// Which `remote_view` tabs a person opened in this process
/// (`RemoteViewTabSource.person`): typed in the address bar, confirmed
/// with Connect, or made by the person's own Open Desktop. Every other local
/// record (CLI, MCP, scripts, agents, bookmarks opened by automation, restore)
/// is unconfirmed and asks before it connects (`RemoteViewTabPolicy`). A
/// confirmation binds one tab, by its key, to the exact record it confirmed;
/// a changed record asks again, and no other tab showing the same record
/// inherits it (#29208). Not persisted: after a relaunch every remote view
/// tab asks again.
@MainActor
final class RemoteViewPageService {
    /// Tab key -> the record URL a person confirmed for it.
    private var confirmed: [String: String] = [:]

    init() {}

    func source(for key: String, url: URL, isLocal: Bool) -> RemoteViewTabSource {
        guard isLocal else { return .remoteTree }
        return confirmed[key] == url.absoluteString ? .person : .unconfirmed
    }

    /// A person opened or confirmed `url` in the tab `key`: typed it, pressed
    /// Connect, or ran Open Desktop, which names the tab the daemon made for
    /// it. Ignored inside an action run that a person did not start (CLI,
    /// MCP, scripts, remote): `bookmark.open` reaches the address bar's load
    /// path too.
    func confirm(_ key: String, url: URL, scope: ActionRunScope? = ActionRunScope.current) {
        guard Self.isPersonInput(scope) else { return }
        confirmed[key] = url.absoluteString
    }

    /// The tab `key` closed or left the remote view page.
    func forget(_ key: String) { confirmed[key] = nil }

    /// No action run (a direct click or key press in this app) or a run a
    /// person started.
    nonisolated static func isPersonInput(_ scope: ActionRunScope?) -> Bool {
        guard let scope else { return true }
        return scope.origin == .user
    }
}
