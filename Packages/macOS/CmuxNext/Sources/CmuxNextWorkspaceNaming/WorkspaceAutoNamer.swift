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
    nonisolated struct Slot: Hashable, Sendable, Encodable {
        var machineID: String
        var workspaceID: String
    }

    /// One rename the rule asks for, and the submission the ledger keys (its slot is the request's).
    nonisolated struct Rename: Equatable, Sendable, Encodable {
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
    /// The key of this namer's submission ledger in Rust (`cmux-workspace-naming` `namer`): each
    /// live workspace's one current submission, at most the current title for a target. The
    /// ledger never wakes the observer: an immediate queue refusal waits for real input to change.
    private let ledger: UInt64
    private let rules = WorkspaceNamingRules()
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

    /// What a rename is fenced by: the daemon run and the name revision.
    private nonisolated struct Fence: Encodable {
        var daemonGeneration: DaemonGeneration?
        var nameRevision: UInt64
    }

    /// One ledger request; the op reads the fields it names.
    private nonisolated struct LedgerRequest: Encodable {
        var namer: UInt64
        var slots: [Slot]?
        var slot: Slot?
        var target: Fence?
        var candidate: Rename?
        var submission: Rename?
        var attempt: UInt64?
        var current: Bool?
    }

    private nonisolated struct Attempt: Decodable { var attempt: UInt64? }
    private nonisolated struct Send: Decodable { var send: Bool; var retry: Bool }

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
        ledger = rules.nextID()
    }

    nonisolated deinit { rules.send("namer_drop", LedgerRequest(namer: ledger)) }

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
        rules.send("namer_list", LedgerRequest(namer: ledger, slots: Array(bySlot.keys)))
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
        let candidate = candidate(target)
        let request = LedgerRequest(namer: ledger, slot: slot,
                                    target: Fence(daemonGeneration: target.daemonGeneration, nameRevision: target.nameRevision),
                                    candidate: candidate)
        // Rust keeps at most the current title for a target, so a late completion for an older
        // title cannot clear a newer same-revision submission.
        return rules.flag("namer_plan", request, key: "rename") ? candidate : nil
    }

    /// The rename the rule asks for in `target`'s workspace, before the ledger's say.
    private func candidate(_ target: Target) -> Rename? {
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
        return Rename(machineID: target.machineID, workspaceID: workspace.id,
                      daemonGeneration: target.daemonGeneration, nameRevision: target.nameRevision,
                      frontTabID: front.id, frontAgentSession: agentSession, name: name)
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
            // The ledger is asked only for a target still current, so a stale one queues nothing.
            guard let target = currentTarget(for: candidate),
                  let attempt = rules.call("namer_begin", LedgerRequest(namer: ledger, slot: slot, submission: candidate),
                                           as: Attempt.self)?.attempt else { continue }
            let maySend: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self else { return false }
                let request = LedgerRequest(namer: ledger, slot: slot, attempt: attempt, current: currentTarget(for: candidate) != nil)
                guard let answer = rules.call("namer_may_send", request, as: Send.self) else { return false }
                if answer.retry { retryMark(slot).revision &+= 1 }
                return answer.send
            }
            let queued = rename(target, candidate.name, maySend) { [weak self] in
                self?.release(slot, attempt: attempt)
            }
            if !queued { release(slot, attempt: attempt) }
        }
    }

    /// The queue refused `attempt`, or an accepted daemon task failed after `maySend` succeeded:
    /// release that exact live attempt. No observation wakeup, so failures stay idle until a real
    /// title, focus or ownership change produces a new candidate.
    private func release(_ slot: Slot, attempt: UInt64) {
        rules.send("namer_release", LedgerRequest(namer: ledger, slot: slot, attempt: attempt))
    }
}
