public import CmuxNextDaemon
import Foundation

extension EmptyWorkspaceRepair {
    /// What ``openAgentBrowserTab(url:engine:profileID:inWorkspace:key:name:on:)`` made.
    public struct AgentBrowserTab: Sendable {
        /// The tab's public id (`tab_…`), the one page verbs take.
        public var tab: String
        public var surface: SurfaceID
        /// The key of the workspace holding it.
        public var workspace: String
    }

    /// An agent's browser tab where no window shows it arriving (`browser.page.right` with no
    /// column right of Home's chat): one more tab in the agents' workspace `workspace` (its key or id), else the one with key `key`, else, none,
    /// a new workspace named `name` whose only tab it is. A daemon create claims no window and
    /// selects nothing, so the person's window, workspace and focus stay. The create tries `key`
    /// (fixed, so a renamed workspace is found again) and, when the daemon will not reuse it (the
    /// person closed that workspace), a fresh key.
    public func openAgentBrowserTab(url: String?, engine: BrowserEngine, profileID: String, inWorkspace workspace: String?,
                                    key: String, name: String, in store: DaemonStore?, on connection: DaemonConnection?) async throws -> AgentBrowserTab {
        guard let connection else { throw DaemonError.notConnected }
        let tab = WorkspaceFirstBrowserTab(url: url ?? "about:blank", engine: engine, profileID: profileID)
        let request = NewFrontendBrowserTabRequest(url: tab.url, engine: engine, profileID: profileID)
        let fixed = WorkspaceKey(rawValue: key)
        let made: NewFrontendBrowserTabRequest.Response, madeIn: String
        // The named workspace, else the one with the fixed key: one more tab there, never a second workspace.
        let named = workspace.flatMap { store?.workspace(key: WorkspaceKey(rawValue: $0)) ?? store?.workspace(id: $0) }
        if let existing = named ?? store?.workspace(key: fixed) {
            made = try await connection.newFrontendBrowserTab(request, inWorkspace: existing.handle)
            madeIn = existing.key?.rawValue ?? existing.id
        } else {
            let created: WorkspaceMutationResult
            do {
                created = try await createBrowserWorkspace(fixed, name: name, tab: tab, on: connection)
            } catch {
                // The daemon will not reuse the key (the person closed that workspace): a fresh one.
                created = try await createBrowserWorkspace(.generate(), name: name, tab: tab, on: connection)
            }
            guard let first = created.firstTab else { throw AgentBrowserTabMissing() }
            made = first
            madeIn = created.key.rawValue
        }
        guard let id = made.tabResourceID?.rawValue else { throw AgentBrowserTabMissing() }
        return AgentBrowserTab(tab: id, surface: made.surface, workspace: madeIn)
    }

    /// The daemon answered without the tab it was asked to make.
    public struct AgentBrowserTabMissing: Error, CustomStringConvertible {
        public var description: String { "the agents' browser workspace answered without its tab" }
    }
}
