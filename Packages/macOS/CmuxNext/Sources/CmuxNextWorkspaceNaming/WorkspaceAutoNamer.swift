import CmuxNextBridge
import CmuxNextCompat
public import CmuxNextDaemon
public import Observation

/// Variant B of workspace auto-naming (`workspaces.autoName.variant` =
/// `persist`, hq#1957): a capable local or remote daemon workspace whose name
/// came from automatic naming follows the generated title of its focused agent
/// chat through Rename Workspace's command. The daemon remains the one writer,
/// so the CLI, window title and search see the same title. Terminal and page
/// titles stay live sidebar labels, and a workspace title or user name stops
/// automatic updates.
///
/// Event-driven: one app-wide observation of daemon stores, the chat titles,
/// the setting and the variant; nothing polls. Process-wide, so two windows
/// showing one workspace send one rename. A rename changes no focus or selection.
@Observable @MainActor
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
        var frontTabID: String
        var frontAgentSession: AgentSessionRef
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
    private let rename: @MainActor (Target, String, @escaping @MainActor @Sendable () -> Bool,
                                    @escaping @MainActor @Sendable () -> Void) -> Bool
    /// Only live targets' current revisions remain here. Bookkeeping never wakes
    /// the observer: an immediate queue refusal waits for real input to change.
    @ObservationIgnored private var submitted: [Submission: AttemptToken] = [:]
    @ObservationIgnored private var nextAttemptID: UInt64 = 0
    /// A deferred cancellation must retry even when its candidate becomes current
    /// again before observation runs. Only that cancellation advances this value.
    private var retryRevision: UInt64 = 0

    private struct AttemptToken: Hashable, Sendable {
        var id: UInt64
    }

    private struct Submission: Hashable, Sendable {
        var machineID: String
        var workspaceID: String
        var daemonGeneration: DaemonGeneration?
        var nameRevision: UInt64
        var frontTabID: String
        var frontAgentSession: AgentSessionRef
        var name: String
    }

    /// - Parameters:
    ///   - names: the rule and front-tab reader.
    ///   - workspaces: all daemon workspaces shown by the app.
    ///   - selection: the window's tab selection in a workspace's pane.
    ///   - rename: schedules the rename, returning false if it cannot be queued.
    ///     It receives a final-send predicate and a completion-failure callback;
    ///     the predicate must run immediately before the daemon request.
    public init(names: WorkspaceAutoNameReader, workspaces: @escaping @MainActor () -> [Target],
                selection: @escaping @MainActor (WorkspaceModel, PaneModel) -> String?,
                rename: @escaping @MainActor (Target, String, @escaping @MainActor @Sendable () -> Bool,
                                               @escaping @MainActor @Sendable () -> Void) -> Bool) {
        self.names = names
        self.workspaces = workspaces
        self.selection = selection
        self.rename = rename
    }

    /// Follows the stores until the task is cancelled; the app runs it for its lifetime.
    public func run() async {
        for await trigger in ObservationStream({ ObservationTrigger(self.pending()) }) { apply(trigger.value) }
    }

    /// The renames the rule asks for now, across local and remote daemon
    /// workspaces that advertise `workspace-name-source-v1`. A machine header
    /// is never a target. Only an automatically named workspace whose front tab is an
    /// agent chat is read further, so terminal/page title changes do not write.
    func pending() -> [Rename] {
        _ = retryRevision
        let targets = workspaces()
        submitted = submitted.filter { entry in
            targets.contains { target in self.matchesTarget(entry.key, target: target) }
        }
        let rule = names.rule
        guard rule.enabled, rule.variant == .persist else { return [] }
        var renames: [Rename] = []
        for target in targets {
            let workspace = target.workspace
            guard target.supportsNameSource, !workspace.isAnyHome, workspace.app == nil,
                  !Self.isUserNamed(target),
                  rule.confirmsRename(currentName: workspace.name, currentTitle: workspace.title,
                                      nameSource: target.nameSource, nameRevision: target.nameRevision),
                  let front = focusedFront(workspace), let agentSession = front.agentSession,
                  let name = rule.persistedName(name: workspace.name, title: workspace.title, front: names.front(front),
                                                isLocalMachine: target.machineID == DaemonCommandScope.localMachine,
                                                supportsNameSource: target.supportsNameSource, alreadyRenamed: false,
                                                nameSource: target.nameSource, nameRevision: target.nameRevision) else { continue }
            let candidate = Rename(machineID: target.machineID, workspaceID: workspace.id,
                                   daemonGeneration: target.daemonGeneration, nameRevision: target.nameRevision,
                                   frontTabID: front.id, frontAgentSession: agentSession, name: name)
            let submission = self.submission(for: candidate)
            // Keep at most the current title for a target. A late completion for an
            // older title then cannot clear a newer same-revision submission.
            submitted = submitted.filter { entry in
                !self.matchesTarget(entry.key, target: target) || entry.key == submission
            }
            guard submitted[submission] == nil else { continue }
            renames.append(candidate)
        }
        return renames
    }

    /// Whether a person named `target`'s workspace, on a daemon that records who did: a
    /// never-renamed `workspace-N` is still the namer's (`WorkspaceAutoName.isUserNamed`).
    private static func isUserNamed(_ target: Target) -> Bool {
        WorkspaceAutoName.isUserNamed(name: target.workspace.name, title: target.workspace.title, nameSource: target.nameSource,
                                      nameRevision: target.nameRevision, allowsLegacyDefaults: false)
    }

    /// Returns the focused tab used by both planning and application so a
    /// queued rename cannot cross a focus, tab-session, or title change.
    private func focusedFront(_ workspace: WorkspaceModel) -> TabModel? {
        SidebarMapping.shared.frontTab(workspace, selectedTab: { [selection] pane in selection(workspace, pane) })
    }

    private func submission(for candidate: Rename) -> Submission {
        Submission(machineID: candidate.machineID, workspaceID: candidate.workspaceID,
                    daemonGeneration: candidate.daemonGeneration, nameRevision: candidate.nameRevision,
                    frontTabID: candidate.frontTabID, frontAgentSession: candidate.frontAgentSession,
                    name: candidate.name)
    }

    private func matchesTarget(_ submission: Submission, target: Target) -> Bool {
        submission.machineID == target.machineID && submission.workspaceID == target.workspace.id
            && submission.daemonGeneration == target.daemonGeneration && submission.nameRevision == target.nameRevision
    }

    /// Reads the target and focused chat again before both scheduling and sending.
    /// The daemon's source/revision CAS fences a manual rename during the request.
    private func currentTarget(for candidate: Rename) -> Target? {
        let rule = names.rule
        guard let target = workspaces().first(where: { $0.machineID == candidate.machineID && $0.workspace.id == candidate.workspaceID }),
              target.workspace.key != nil, target.daemonGeneration == candidate.daemonGeneration,
              target.nameRevision == candidate.nameRevision,
              !Self.isUserNamed(target), target.supportsNameSource,
              !target.workspace.isAnyHome, target.workspace.app == nil,
              rule.confirmsRename(currentName: target.workspace.name, currentTitle: target.workspace.title,
                                  nameSource: target.nameSource, nameRevision: target.nameRevision),
              let front = focusedFront(target.workspace), front.id == candidate.frontTabID,
              front.agentSession == candidate.frontAgentSession,
              let name = rule.persistedName(name: target.workspace.name, title: target.workspace.title,
                                            front: names.front(front),
                                            isLocalMachine: target.machineID == DaemonCommandScope.localMachine,
                                            supportsNameSource: target.supportsNameSource, alreadyRenamed: false,
                                            nameSource: target.nameSource, nameRevision: target.nameRevision),
              name == candidate.name else { return nil }
        return target
    }

    /// Queues each revision once. A deferred send rechecks the same candidate;
    /// skipping it releases the submission and wakes observation for a later retry.
    func apply(_ renames: [Rename]) {
        for candidate in renames {
            let submission = self.submission(for: candidate)
            guard submitted[submission] == nil, let target = currentTarget(for: candidate) else { continue }
            let attempt = AttemptToken(id: nextAttemptID)
            nextAttemptID &+= 1
            submitted[submission] = attempt
            let maySend: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self, submitted[submission] == attempt else { return false }
                guard currentTarget(for: candidate) != nil else {
                    if submitted[submission] == attempt {
                        submitted.removeValue(forKey: submission)
                        retryRevision &+= 1
                    }
                    return false
                }
                return true
            }
            let queued = rename(target, candidate.name, maySend) { [weak self] in
                self?.acceptedSendFailed(submission, attempt: attempt)
            }
            if !queued, submitted[submission] == attempt { submitted.removeValue(forKey: submission) }
        }
    }

    /// An accepted daemon task can fail after `maySend` succeeds. Release only
    /// that exact live attempt; no observation wakeup means failures stay idle
    /// until a real title/focus/ownership change produces a new candidate.
    private func acceptedSendFailed(_ submission: Submission, attempt: AttemptToken) {
        guard submitted[submission] == attempt else { return }
        submitted.removeValue(forKey: submission)
    }
}
