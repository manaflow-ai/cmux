import CmuxNextBridge
import CmuxNextCompat
public import CmuxNextDaemon

/// Variant B of workspace auto-naming (`workspaces.autoName.variant` =
/// `persist`, hq#1957): the first time a default-named workspace of a
/// capable local or remote daemon has an agent chat in front whose chat has a
/// real title (the agent's, never its first prompt), it is renamed once
/// through Rename Workspace's command (`rename-workspace`; the daemon stays
/// the one writer), so the CLI, window title and search see the name.
/// Terminal and page titles stay live sidebar labels. Never again for that
/// name revision, and never one the user named (`WorkspaceAutoName.persistedName`).
///
/// Event-driven: one app-wide observation of daemon stores, the chat
/// titles, the setting and the variant; nothing polls. Process-wide, so two
/// windows showing one workspace send one rename. A rename changes no
/// focus or selection.
@MainActor
public final class WorkspaceAutoNamer {
    /// The identity and name state read immediately before an automatic rename.
    /// A target is supplied by the App so the naming module never conflates a
    /// workspace with a machine header or routes a remote row to the local daemon.
    public struct Target {
        public let machineID: String
        public let workspace: WorkspaceModel
        public let supportsNameSource: Bool
        public let daemonGeneration: DaemonGeneration?
        public let nameSource: WorkspaceNameSource
        public let nameRevision: UInt64

        public init(machineID: String, workspace: WorkspaceModel, supportsNameSource: Bool,
                    daemonGeneration: DaemonGeneration?, nameSource: WorkspaceNameSource,
                    nameRevision: UInt64) {
            self.machineID = machineID
            self.workspace = workspace
            self.supportsNameSource = supportsNameSource
            self.daemonGeneration = daemonGeneration
            self.nameSource = nameSource
            self.nameRevision = nameRevision
        }
    }

    /// One rename the rule asks for.
    struct Rename: Equatable, Sendable {
        var machineID: String
        var workspaceID: String
        var daemonGeneration: DaemonGeneration?
        var nameRevision: UInt64
        var name: String
    }

    private let names: WorkspaceAutoNameReader
    /// Every shown daemon workspace. The App supplies machine identity and
    /// capability state; this keeps local and remote naming on one policy.
    private let workspaces: @MainActor () -> [Target]
    /// The tab the window showing a workspace selected in a pane, else nil for its default tab.
    private let selection: @MainActor (WorkspaceModel, PaneModel) -> String?
    /// Sends `rename-workspace` with source and revision guards. The App owns
    /// the connection and must reject missing capabilities without writing.
    private let rename: @MainActor (Target, String) -> Void
    /// Targets already submitted in this run. The revision remains part of the
    /// identity so a later generated title can retry after a stale response.
    private var submitted: Set<Submission> = []

    private struct Submission: Hashable {
        var machineID: String
        var workspaceID: String
        var daemonGeneration: DaemonGeneration?
        var nameRevision: UInt64
    }

    /// - Parameters:
    ///   - names: the rule and front-tab reader.
    ///   - workspaces: all daemon workspaces shown by the app.
    ///   - selection: the window's tab selection in a workspace's pane.
    ///   - rename: sends the guarded rename to the target daemon.
    public init(names: WorkspaceAutoNameReader, workspaces: @escaping @MainActor () -> [Target],
                selection: @escaping @MainActor (WorkspaceModel, PaneModel) -> String?,
                rename: @escaping @MainActor (Target, String) -> Void) {
        self.names = names
        self.workspaces = workspaces
        self.selection = selection
        self.rename = rename
    }

    /// Follows the stores until the task is cancelled; the app runs it for its lifetime.
    public func run() async {
        for await renames in ObservationStream({ self.pending() }) { apply(renames) }
    }

    /// The renames the rule asks for now, across local and remote daemon
    /// workspaces that advertise `workspace-name-source-v1`. A machine header
    /// is never a target. Only a default-named workspace whose front tab is an
    /// agent chat is read further, so terminal/page title changes do not write.
    func pending() -> [Rename] {
        let rule = names.rule
        guard rule.enabled, rule.variant == .persist else { return [] }
        var renames: [Rename] = []
        for target in workspaces() {
            let workspace = target.workspace
            let submission = Submission(machineID: target.machineID, workspaceID: workspace.id,
                                        daemonGeneration: target.daemonGeneration, nameRevision: target.nameRevision)
            guard target.supportsNameSource, workspace.kind != SidebarMapping.homeKind, workspace.app == nil,
                  !submitted.contains(submission), target.nameSource == .auto,
                  rule.confirmsRename(currentName: workspace.name, currentTitle: workspace.title,
                                      nameSource: target.nameSource, nameRevision: target.nameRevision),
                  let front = SidebarMapping.shared.frontTab(workspace, selectedTab: { [selection] pane in selection(workspace, pane) }),
                  front.agentSession != nil,
                  let name = rule.persistedName(name: workspace.name, title: workspace.title, front: names.front(front),
                                                isLocalMachine: target.machineID == DaemonCommandScope.localMachine,
                                                supportsNameSource: target.supportsNameSource, alreadyRenamed: false,
                                                nameSource: target.nameSource, nameRevision: target.nameRevision) else { continue }
            renames.append(Rename(machineID: target.machineID, workspaceID: workspace.id,
                                  daemonGeneration: target.daemonGeneration, nameRevision: target.nameRevision, name: name))
        }
        return renames
    }

    /// Sends each revision once after re-reading the target identity. The
    /// daemon's source/revision CAS is the final fence: manual names and a
    /// newer generated result win, even when an older completion returns late.
    func apply(_ renames: [Rename]) {
        let rule = names.rule
        for candidate in renames {
            let submission = Submission(machineID: candidate.machineID, workspaceID: candidate.workspaceID,
                                        daemonGeneration: candidate.daemonGeneration, nameRevision: candidate.nameRevision)
            guard !submitted.contains(submission),
                  let target = workspaces().first(where: { $0.machineID == candidate.machineID && $0.workspace.id == candidate.workspaceID }),
                  let key = target.workspace.key, target.daemonGeneration == candidate.daemonGeneration,
                  target.nameRevision == candidate.nameRevision,
                  target.nameSource == .auto, target.supportsNameSource,
                  rule.confirmsRename(currentName: target.workspace.name, currentTitle: target.workspace.title,
                                      nameSource: target.nameSource, nameRevision: target.nameRevision) else { continue }
            submitted.insert(submission)
            rename(target, candidate.name)
        }
    }
}
