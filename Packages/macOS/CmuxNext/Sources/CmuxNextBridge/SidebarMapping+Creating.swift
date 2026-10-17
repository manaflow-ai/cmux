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

    /// The names `defaultWorkspaceName` reads from `store`: every listed
    /// workspace but the home workspace.
    @MainActor public static func defaultNameInputs(_ store: DaemonStore) -> [String] {
        store.workspaces.filter { $0.kind != homeKind }.map(\.name)
    }

    /// The row of workspace `id` on `machine` while it is created: titled
    /// `title`, with `cwd` as its folder line, shortened as the live row
    /// shortens it (this Mac's home on the local machine, the remote home
    /// elsewhere).
    public func creatingRow(id: String, machine: MachineID, title: String, cwd: String?) -> SidebarWorkspace {
        let shorten: (String) -> String = machine == .local ? { abbreviate($0) } : Self.abbreviateRemote
        return SidebarWorkspace(id: SidebarWorkspaceID(id), machineID: machine, title: title,
                                directory: cwd.map(shorten), rowState: .creating)
    }
}
