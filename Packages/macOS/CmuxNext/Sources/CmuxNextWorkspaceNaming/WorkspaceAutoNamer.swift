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
/// Event-driven, nothing polls: one observation of which workspaces are shown
/// (the list, never a workspace's fields), and one per workspace of its name,
/// front chat's title, the setting and the variant. A change to one workspace
/// plans that workspace alone, so its cost does not grow with the workspaces
/// shown (perf-speed-of-light.md I1, I2). Process-wide, so two windows
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

    /// A shown daemon workspace and its machine, without its name state: the list of
    /// these is observed for membership only, so a rename elsewhere does not wake it.
    public struct Shown: Sendable {
        public let machineID: String
        public let workspace: WorkspaceModel
        public let supportsNameSource: Bool
        public let daemonGeneration: DaemonGeneration?

        public init(machineID: String, workspace: WorkspaceModel, supportsNameSource: Bool,
                    daemonGeneration: DaemonGeneration?) {
            self.machineID = machineID
            self.workspace = workspace
            self.supportsNameSource = supportsNameSource
            self.daemonGeneration = daemonGeneration
        }

        /// The target with the name state read now.
        @MainActor var target: Target {
            Target(machineID: machineID, workspace: workspace, supportsNameSource: supportsNameSource,
                   daemonGeneration: daemonGeneration, nameSource: workspace.nameSource,
                   nameRevision: workspace.nameRevision)
        }

        @MainActor var slot: Slot { Slot(machineID: machineID, workspaceID: workspace.id) }

        /// The same workspace object on the same daemon run, so its observation still holds.
        @MainActor func isSame(as other: Shown) -> Bool {
            other.workspace === workspace && other.daemonGeneration == daemonGeneration
                && other.supportsNameSource == supportsNameSource
        }
    }

    /// A workspace on a machine: the key of its submission, retry mark and observation.
    struct Slot: Hashable, Sendable {
        var machineID: String
        var workspaceID: String
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
    /// It must not read a workspace's fields: its observation wakes on list changes only.
    private let workspaces: @MainActor () -> [Shown]
    /// The tab the window showing a workspace selected in a pane, else nil for its default tab.
    private let selection: @MainActor (WorkspaceModel, PaneModel) -> String?
    /// Sends `rename-workspace` with source and revision guards. The App owns
    /// the connection and must reject missing capabilities without writing.
    private let rename: @MainActor (Target, String, @escaping @MainActor @Sendable () -> Bool,
                                    @escaping @MainActor @Sendable () -> Void) -> Bool
    /// Each live workspace's one current submission (at most the current title for a
    /// target). Bookkeeping never wakes the observer: an immediate queue refusal waits
    /// for real input to change.
    @ObservationIgnored private var submitted: [Slot: Live] = [:]
    @ObservationIgnored private var nextAttemptID: UInt64 = 0
    /// The workspaces listed last, by slot: a candidate's target is found here, not by a
    /// walk of the list.
    @ObservationIgnored private var shown: [Slot: Shown] = [:]
    /// Each workspace's retry mark. A deferred cancellation must retry even when its
    /// candidate becomes current again before observation runs; only that cancellation
    /// advances a mark, and it wakes that workspace's observation alone.
    @ObservationIgnored private var retries: [Slot: RetryMark] = [:]

    @Observable @MainActor
    final class RetryMark {
        var revision: UInt64 = 0
    }

    private struct Live {
        var submission: Submission
        var attempt: AttemptToken
    }

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
    public init(names: WorkspaceAutoNameReader, workspaces: @escaping @MainActor () -> [Shown],
                selection: @escaping @MainActor (WorkspaceModel, PaneModel) -> String?,
                rename: @escaping @MainActor (Target, String, @escaping @MainActor @Sendable () -> Bool,
                                               @escaping @MainActor @Sendable () -> Void) -> Bool) {
        self.names = names
        self.workspaces = workspaces
        self.selection = selection
        self.rename = rename
    }

    /// Follows the stores until the task is cancelled; the app runs it for its lifetime.
    /// The list is observed for membership; each workspace has its own observation,
    /// started when it is first listed and stopped when it leaves the list.
    public func run() async {
        var watches: [Slot: (shown: Shown, task: Task<Void, Never>)] = [:]
        defer { for watch in watches.values { watch.task.cancel() } }
        for await trigger in ObservationStream({ ObservationTrigger(self.workspaces()) }) {
            list(trigger.value)
            var next: [Slot: (shown: Shown, task: Task<Void, Never>)] = [:]
            for listed in trigger.value where next[listed.slot] == nil {
                let slot = listed.slot
                if let watch = watches.removeValue(forKey: slot) {
                    if watch.shown.isSame(as: listed) { next[slot] = watch; continue }
                    watch.task.cancel()
                }
                next[slot] = (listed, observe(listed))
            }
            for watch in watches.values { watch.task.cancel() }
            watches = next
        }
    }

    /// Plans `listed` now and again whenever what its plan read changes.
    private func observe(_ listed: Shown) -> Task<Void, Never> {
        let (first, later) = ObservationStream.current({ [weak self] in ObservationTrigger(self?.plan(listed)) })
        apply(first.value.map { [$0] } ?? [])
        return Task { [weak self] in
            for await next in later {
                guard let self else { return }
                apply(next.value.map { [$0] } ?? [])
            }
        }
    }

    /// Records the listed workspaces; a workspace no longer listed keeps no submission or retry mark.
    private func list(_ listed: [Shown]) {
        var bySlot: [Slot: Shown] = [:]
        for item in listed where bySlot[item.slot] == nil { bySlot[item.slot] = item }
        shown = bySlot
        submitted = submitted.filter { bySlot[$0.key] != nil }
        retries = retries.filter { bySlot[$0.key] != nil }
    }

    /// The renames the rule asks for now, across every listed workspace (one plan
    /// each). `run()` plans one workspace per change instead.
    func pending() -> [Rename] {
        let listed = workspaces()
        list(listed)
        return listed.compactMap { plan($0) }
    }

    /// The rename the rule asks for in one workspace that advertises
    /// `workspace-name-source-v1`. A machine header is never a target. Only an
    /// automatically named workspace whose front tab is an agent chat is read further,
    /// so terminal/page title changes do not write. Reads that workspace's fields only.
    func plan(_ listed: Shown) -> Rename? {
        let slot = listed.slot
        _ = retryMark(slot).revision
        let target = listed.target
        if let live = submitted[slot], !matchesTarget(live.submission, target: target) { submitted[slot] = nil }
        let rule = names.rule
        guard rule.enabled, rule.variant == .persist else { return nil }
        let workspace = target.workspace
        guard target.supportsNameSource, !workspace.isAnyHome, workspace.app == nil,
              !Self.isUserNamed(target),
              rule.confirmsRename(currentName: workspace.name, currentTitle: workspace.title,
                                  nameSource: target.nameSource, nameRevision: target.nameRevision),
              let front = focusedFront(workspace), let agentSession = front.agentSession,
              let name = rule.persistedName(name: workspace.name, title: workspace.title, front: names.front(front),
                                            isLocalMachine: target.machineID == DaemonCommandScope.localMachine,
                                            supportsNameSource: target.supportsNameSource, alreadyRenamed: false,
                                            nameSource: target.nameSource, nameRevision: target.nameRevision) else { return nil }
        let candidate = Rename(machineID: target.machineID, workspaceID: workspace.id,
                               daemonGeneration: target.daemonGeneration, nameRevision: target.nameRevision,
                               frontTabID: front.id, frontAgentSession: agentSession, name: name)
        let submission = self.submission(for: candidate)
        // Keep at most the current title for a target. A late completion for an
        // older title then cannot clear a newer same-revision submission.
        if let live = submitted[slot] {
            guard live.submission != submission else { return nil }
            submitted[slot] = nil
        }
        return candidate
    }

    private func retryMark(_ slot: Slot) -> RetryMark {
        if let mark = retries[slot] { return mark }
        let mark = RetryMark()
        retries[slot] = mark
        return mark
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
        guard let target = shown[Slot(machineID: candidate.machineID, workspaceID: candidate.workspaceID)]?.target,
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
    /// skipping it releases the submission and wakes its workspace's observation for a later retry.
    func apply(_ renames: [Rename]) {
        for candidate in renames {
            let slot = Slot(machineID: candidate.machineID, workspaceID: candidate.workspaceID)
            let submission = self.submission(for: candidate)
            guard submitted[slot]?.submission != submission, let target = currentTarget(for: candidate) else { continue }
            let attempt = AttemptToken(id: nextAttemptID)
            nextAttemptID &+= 1
            submitted[slot] = Live(submission: submission, attempt: attempt)
            let maySend: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self, submitted[slot]?.attempt == attempt else { return false }
                guard currentTarget(for: candidate) != nil else {
                    if submitted[slot]?.attempt == attempt {
                        submitted[slot] = nil
                        retryMark(slot).revision &+= 1
                    }
                    return false
                }
                return true
            }
            let queued = rename(target, candidate.name, maySend) { [weak self] in
                self?.acceptedSendFailed(slot, attempt: attempt)
            }
            if !queued, submitted[slot]?.attempt == attempt { submitted[slot] = nil }
        }
    }

    /// An accepted daemon task can fail after `maySend` succeeds. Release only
    /// that exact live attempt; no observation wakeup means failures stay idle
    /// until a real title/focus/ownership change produces a new candidate.
    private func acceptedSendFailed(_ slot: Slot, attempt: AttemptToken) {
        guard submitted[slot]?.attempt == attempt else { return }
        submitted[slot] = nil
    }
}
