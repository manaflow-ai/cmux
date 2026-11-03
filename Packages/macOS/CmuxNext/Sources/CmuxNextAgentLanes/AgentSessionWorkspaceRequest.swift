public import CmuxNextActions
public import CmuxNextDaemon
import CmuxNextSidebar
import Foundation

/// The arguments of `agent.openSessionWorkspace` (the App's `AgentSessionWorkspace`), read and checked
/// before anything opens: `session` (required, the acpmux session id), `name` (the workspace name),
/// `defaultName` (the name a workspace with no `name` takes in place of `workspace-N`: an unnamed
/// `acpmux new --group` launch's session name; it never reuses a predecessor row, so two sessions of the
/// same generated name never share one), `key` (a caller-chosen workspace key, a lowercase UUID, so the
/// caller can rename the workspace later), `cwd` (unused: the session keeps its own), `host`
/// (`chief:<home id>`: the session runs in this app's Chief home's acpmux), `group` (the name of the
/// sidebar group it goes in: any group of that name that can hold the row, made only when none can;
/// `acpmux new --group` sends it), `placement` (`top`: first below Home over `workspaces.newPlacement`,
/// `agents chat new --top`).
public struct AgentSessionWorkspaceRequest: Sendable, Equatable {
    /// Why the arguments open nothing; its description is the refusal the caller reads.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The acpmux session id, trimmed.
    public let session: String
    public let name: String?
    /// Nil when absent or only white space.
    public let defaultName: String?
    /// The caller's key when it is a UUID (lowercased), else a fresh one.
    public let key: WorkspaceKey
    public let cwd: String?
    /// The Chief host's own acpmux runs the session (`chief:<home id>`); nil: this Mac's.
    public let host: String?
    /// As given, so a group whose name has outer spaces is still found exactly; a new group gets the
    /// trimmed name (`AgentSessionWorkspace.join`).
    public let group: String?
    /// `placement: top`.
    public let top: Bool

    /// Reads `invocation`'s arguments. Refuses a missing `session` with `sessionRequired`, a `group`
    /// that is a cmux id or blank, and a `placement` other than `top`.
    public init(_ invocation: ActionInvocation, sessionRequired: @autoclosure () -> String) throws(Refusal) {
        let nonEmpty = { (argument: String) in invocation[argument]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
        session = (invocation["session"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !session.isEmpty else { throw Refusal(description: sessionRequired()) }
        name = nonEmpty("name")
        defaultName = invocation["defaultName"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let given = invocation["key"]?.stringValue?.lowercased()
        key = given.flatMap { UUID(uuidString: $0) == nil ? nil : WorkspaceKey(rawValue: $0) } ?? .generate()
        cwd = nonEmpty("cwd")
        host = nonEmpty("host")
        group = nonEmpty("group")
        if let group, !SidebarEdits.validGroupName(group) {
            throw Refusal(description: "agent.openSessionWorkspace: group must be a non-empty human label, not a cmux id; omit group or use a label such as \"GUI push\"")
        }
        let placement = invocation["placement"]?.stringValue ?? ""
        guard ["", "top"].contains(placement) else {
            throw Refusal(description: "agent.openSessionWorkspace: placement must be top; omit it for the workspaces.newPlacement setting")
        }
        top = placement == "top"
    }
}
