public import CmuxNextBridge
public import CmuxNextDaemon
public import CmuxNextSidebar
import Foundation

/// The sidebar row of a workspace this app is creating, from the press until
/// the daemon lists it (Lawrence, 2026-10-16: "Why is there a loading state
/// for workspaces? This needs to be instant."). The row is drawn at the press
/// in the look the live row will have, so the daemon's reply changes nothing
/// on screen: the name the app gives the create, its folder line, and no
/// placeholder bar (`SidebarRowState.creating`).
extension SidebarMapping {
    /// The daemon's default for the next workspace (`workspace-N`, cmux-tui
    /// `Mux::default_workspace_name`): one more than the highest `workspace-N`
    /// name and than the count of workspaces (the home workspace not counted).
    /// `existing` are the machine's listed workspace names (home left out);
    /// `reserved` are the names given to creates the daemon has not listed
    /// yet, so a key-repeat burst numbers each create once, in press order.
    /// The app sends this name with the create, so the row's title is the
    /// daemon's title from the press.
    public static func defaultWorkspaceName(existing: [String], reserved: [String]) -> String {
        func number(_ name: String) -> Int? {
            guard name.hasPrefix(defaultNamePrefix) else { return nil }
            let digits = name.dropFirst(defaultNamePrefix.count)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(digits)
        }
        // A reserved name the machine lists already is counted once.
        let unlisted = reserved.filter { !existing.contains($0) }
        let highest = (existing + unlisted).compactMap(number).max() ?? 0
        return defaultNamePrefix + String(max(highest, existing.count + unlisted.count) + 1)
    }

    /// The prefix of the daemon's default workspace names.
    public static let defaultNamePrefix = "workspace-"

    /// `defaultWorkspaceName` for the machine of `store`: its listed
    /// workspaces but the home workspace.
    @MainActor public static func nextWorkspaceName(in store: DaemonStore, reserved: [String]) -> String {
        defaultWorkspaceName(existing: store.workspaces.filter { $0.kind != homeKind }.map(\.name), reserved: reserved)
    }

    /// The row of workspace `id` on `machine` while it is created, as the
    /// window first lists it: titled `name`, as the live rule (`sidebarTitle`)
    /// will title it, with no folder line yet (the
    /// daemon lists a new workspace before its first tab reports a folder),
    /// an agent row when it opens on the New Tab page (`opensPage`, its first
    /// tab a conversation), else a terminal row.
    public func creatingRow(id: String, machine: MachineID, name: String, opensPage: Bool) -> SidebarWorkspace {
        SidebarWorkspace(id: SidebarWorkspaceID(id), machineID: machine, title: name,
                         rowKind: opensPage ? .agent : .terminal,
                         kind: opensPage ? .harness : .terminal, rowState: .creating)
    }
}
