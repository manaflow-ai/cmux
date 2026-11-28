import CmuxNextActions
import Foundation
import CmuxNextRemoteView

/// Which `remote_view` tabs a person opened in this process
/// (`RemoteViewTabSource.person`): typed in the address bar, or confirmed
/// with Connect. Every other local record (CLI, MCP, scripts, agents,
/// bookmarks opened by automation, restore) is unconfirmed and asks before
/// it connects (`RemoteViewTabPolicy`). A confirmation binds the tab to the
/// exact record it confirmed; a changed record asks again. Not persisted:
/// after a relaunch every remote view tab asks again.
@MainActor
final class RemoteViewPageService {
    /// Tab key -> the record URL a person confirmed for it.
    private var confirmed: [String: String] = [:]

    func source(for key: String, url: URL, isLocal: Bool) -> RemoteViewTabSource {
        guard isLocal else { return .remoteTree }
        return confirmed[key] == url.absoluteString ? .person : .unconfirmed
    }

    /// A person opened or confirmed `url` in the tab `key`. Ignored inside
    /// an action run that a person did not start (CLI, MCP, scripts,
    /// remote): `bookmark.open` reaches the address bar's load path too.
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
