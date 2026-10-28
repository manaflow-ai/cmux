import CmuxNextSettings
import Foundation

/// Where a `cmux browser` input came from: the terminal or chat its agent
/// runs in (the request's `caller`), for the agent cursor's tag. The tag
/// says who drives and where ("a201 · cursor-gallery", "Chief · Home"), and
/// a click on it shows ``tabID`` (user, 2026-10-20).
public struct BrowserPageAgentOrigin: Sendable, Equatable {
    /// A Chief turn (`caller.home_chat`): the tag names the Chief, not the
    /// harness ("Claude").
    public var isChief: Bool
    /// The caller's workspace, by its public id (`ws_…`).
    public var workspaceID: String
    /// The caller's workspace as the sidebar names it: its title, else its name.
    public var workspaceName: String
    /// The caller's own tab (its terminal or chat): a click on the tag shows it.
    public var tabID: String

    /// - Parameters:
    ///   - isChief: Whether a Chief turn sent the input.
    ///   - workspaceID: The caller's workspace public id.
    ///   - workspaceName: The caller's workspace title or name.
    ///   - tabID: The caller's tab.
    public init(isChief: Bool, workspaceID: String, workspaceName: String, tabID: String) {
        self.isChief = isChief
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.tabID = tabID
    }

    /// The origin of a request's `caller` in `topology`; nil when the request
    /// names no caller (or a malformed one) or the topology does not show it.
    static func resolve(params: [String: JSONValue], topology: ControlTopology) -> Self? {
        guard let caller = try? ControlCaller(params),
              let location = ControlCallerLocation.resolve(caller, in: topology) else { return nil }
        let workspace = location.workspace
        let title = workspace.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Self(isChief: caller.homeChat, workspaceID: workspace.publicID,
                    workspaceName: title.isEmpty ? workspace.name : title, tabID: location.tab.id)
    }
}
