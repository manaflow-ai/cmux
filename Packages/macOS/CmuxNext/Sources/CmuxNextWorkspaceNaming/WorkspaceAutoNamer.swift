import CmuxNextBridge
import CmuxNextCompat
public import CmuxNextDaemon

/// Variant B of workspace auto-naming (`workspaces.autoName.variant` =
/// `persist`, hq#1957): the first time a default-named workspace of this
/// Mac's daemon has an agent chat in front whose chat has a real title (the
/// agent's, never its first prompt), it is renamed once through Rename
/// Workspace's command (`rename-workspace`; the daemon stays the one writer),
/// so the CLI, the window title and search see the name. Terminal and page
/// titles stay live sidebar labels. Never again for that workspace, and
/// never one the user named (`WorkspaceAutoName.persistedName`).
///
/// Event-driven: one app-wide observation of the local store, the chat
/// titles, the setting and the variant; nothing polls. Process-wide, so two
/// windows showing one workspace send one rename. A rename changes no
/// focus or selection.
@MainActor
public final class WorkspaceAutoNamer {
    /// One rename the rule asks for.
    struct Rename: Equatable, Sendable {
        var workspaceID: String
        var name: String
    }

    private let names: WorkspaceAutoNameReader
    /// This Mac's daemon's workspaces (never a remote or Cloud machine's).
    private let workspaces: @MainActor () -> [WorkspaceModel]
    /// The tab the window showing a workspace selected in a pane, else nil for its default tab.
    private let selection: @MainActor (WorkspaceModel, PaneModel) -> String?
    /// Sends `rename-workspace` to this Mac's daemon (Rename Workspace's command).
    private let rename: @MainActor (WorkspaceKey, String) -> Void
    /// Workspaces this app renamed or asked to rename: never again, even if
    /// the rename failed or the name went back to a default one.
    private var renamed: Set<String> = []

    /// - Parameters:
    ///   - names: the rule and front-tab reader.
    ///   - workspaces: the local daemon's workspaces.
    ///   - selection: the window's tab selection in a workspace's pane.
    ///   - rename: sends the rename to the local daemon.
    public init(names: WorkspaceAutoNameReader, workspaces: @escaping @MainActor () -> [WorkspaceModel],
                selection: @escaping @MainActor (WorkspaceModel, PaneModel) -> String?,
                rename: @escaping @MainActor (WorkspaceKey, String) -> Void) {
        self.names = names
        self.workspaces = workspaces
        self.selection = selection
        self.rename = rename
    }

    /// Follows the stores until the task is cancelled; the app runs it for its lifetime.
    public func run() async {
        for await renames in ObservationStream({ self.pending() }) { apply(renames) }
    }

    /// The renames the rule asks for now, among this Mac's daemon's
    /// workspaces only (a remote or Cloud workspace is never renamed, so two
    /// Macs on one daemon never race; the Home workspace and app workspaces
    /// keep their names). Only a default-named workspace whose front tab is
    /// an agent chat is read further, so a terminal's title ticks or a
    /// page's loads never wake this.
    func pending() -> [Rename] {
        let rule = names.rule
        guard rule.enabled, rule.variant == .persist else { return [] }
        var renames: [Rename] = []
        for workspace in workspaces()
        where workspace.kind != SidebarMapping.homeKind && workspace.app == nil && !renamed.contains(workspace.id)
            && rule.confirmsRename(currentName: workspace.name, currentTitle: workspace.title) {
            guard let front = SidebarMapping.shared.frontTab(workspace, selectedTab: { [selection] pane in selection(workspace, pane) }),
                  front.agentSession != nil,
                  let name = rule.persistedName(name: workspace.name, title: workspace.title, front: names.front(front),
                                                isLocalMachine: true, alreadyRenamed: false) else { continue }
            renames.append(Rename(workspaceID: workspace.id, name: name))
        }
        return renames
    }

    /// Sends each rename once, unless the user named the workspace since
    /// (`confirmsRename` on its current name and title). `rename-workspace`
    /// takes no expected old name, so a rename the user sends in the same
    /// instant can still lose to this one.
    func apply(_ renames: [Rename]) {
        let rule = names.rule
        for candidate in renames where !renamed.contains(candidate.workspaceID) {
            renamed.insert(candidate.workspaceID)
            guard let workspace = workspaces().first(where: { $0.id == candidate.workspaceID }), let key = workspace.key,
                  rule.confirmsRename(currentName: workspace.name, currentTitle: workspace.title) else { continue }
            rename(key, candidate.name)
        }
    }
}
