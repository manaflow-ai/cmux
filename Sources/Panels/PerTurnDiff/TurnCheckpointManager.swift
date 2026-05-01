import Foundation
import Combine

/// Protocol abstracting the parts of Workspace we need (allows test stubs).
@MainActor
protocol TurnCheckpointManagerWorkspace: AnyObject {
    var id: UUID { get }
    var statusEntriesPublisher: Published<[String: SidebarStatusEntry]>.Publisher { get }
    var currentDirectoryPublisher: Published<String>.Publisher { get }
    var statusEntries: [String: SidebarStatusEntry] { get }
    var currentDirectory: String { get }
    /// Pwd of the focused terminal pane; used by ClaudeTranscriptTailer as the
    /// transcript-cwd anchor (which decides which `~/.claude/projects/...` dir
    /// to tail) and by the FSEvents fallback as a watch root.
    var focusedPanePwd: String? { get }
}

/// Lazy-snapshot orchestrator for one workspace.
/// Subscribes to claude_code status entry; on idle→running captures T_start tree;
/// on running→idle compares T_end and updates the in-memory baseline iff something changed.
///
/// The git root tracked here is dynamic: callers (TurnCheckpointRegistry) update
/// it whenever the focused terminal pane's pwd changes, by walking up to the
/// nearest `.git` ancestor. While `currentRoot == nil` the manager is idle.
///
/// Baselines used to be stored as refs/cmux/session-<wsId>/last-turn-base in
/// the user's `.git/refs/`, with parent-less commits/trees in the user's
/// `.git/objects/`. That polluted `git fsck`/`for-each-ref` and accumulated
/// disk inside the user's repo. The current design keeps tree/commit objects
/// inside cmux's per-(ws, repo) object store under
/// `~/Library/Application Support/cmux/diff-state/...`, and tracks the
/// per-repo baseline tree SHA in `baselineTreesByRoot` here. No `update-ref`
/// calls are ever made against the user's repo.
@MainActor
final class TurnCheckpointManager {
    /// Status-key the snapshot algorithm watches. Constant for v1 (Claude Code only).
    static let statusKey = "claude_code"

    private weak var workspace: (any TurnCheckpointManagerWorkspace)?
    private let session: UUID
    private var cancellables: Set<AnyCancellable> = []

    /// Active git root, or nil if the focused pane isn't inside a git repo.
    private(set) var currentRoot: String?

    /// All git roots visited during this session, in order of first visit.
    /// The most-recently-active root is appended (or moved) to the END of the
    /// array so the React panel can default-expand the latest repo group.
    /// Insertion is deduped: revisiting an existing root just moves it to the
    /// end without creating a duplicate entry.
    private(set) var visitedRoots: [String] = []

    /// Per-repo baseline tree SHA (cmux store object), keyed by repo path.
    /// Replaces the old `refs/cmux/session-<wsId>/last-turn-base` storage.
    /// nil entry / missing entry => Tier 1 unavailable, fall through to HEAD.
    private var baselineTreesByRoot: [String: String] = [:]

    /// One root + its rendered diff, for the multi-repo grouped view.
    /// Emitted to the React panel via `onMultiDiffChanged`.
    struct RepoDiff {
        let root: String
        let diff: String
        let isActive: Bool
    }

    /// Cached tree SHA captured at last idle→running. nil while agent is idle.
    private var pendingStartTree: String?

    /// Root that was active at idle→running. Used at captureEnd to detect
    /// whether the turn actually modified that repo before committing the
    /// pre-turn snapshot as the new baseline. May differ from `currentRoot`
    /// if the agent switches roots mid-turn (transcript tail detection lags).
    private var pendingStartRoot: String?

    /// Most recent status string seen.
    private var lastStatus: String?

    /// Set by TurnDiffPanelHost; called when the multi-repo diff should refresh.
    /// Payload contains one entry per visited root, ordered oldest-first; the
    /// active root has `isActive == true`.
    var onMultiDiffChanged: (([RepoDiff]) -> Void)?

    /// Set by TurnDiffPanelHost; called on running/idle state changes.
    var onStatusChanged: ((String) -> Void)?

    /// Set by TurnDiffPanelHost; called when files change mid-turn (debounced via WorktreeWatcher).
    /// Mirrors `onMultiDiffChanged` shape so live edits in any visited repo
    /// flow through the grouped view, not just the active one.
    var onLiveMultiDiffChanged: (([RepoDiff]) -> Void)?

    /// Set by TurnDiffPanelHost; fired when the active git root changes.
    /// `(newRoot: String?, hasGitRoot: Bool, observedCwd: String?)`
    /// observedCwd is the focused pane's pwd that was probed (for empty-state copy).
    var onRootChanged: ((String?, Bool, String?) -> Void)?

    private var watcher: WorktreeWatcher?

    init(workspace: any TurnCheckpointManagerWorkspace, currentRoot: String? = nil) {
        self.workspace = workspace
        self.session = workspace.id
        self.currentRoot = currentRoot
        if let root = currentRoot, !root.isEmpty {
            self.visitedRoots = [root]
        }
    }

    func start() {
        guard let workspace else { return }
        // Best-effort migration: clear any legacy refs/cmux/session-<ws>/...
        // refs that prior versions of cmux wrote into the user's .git/refs/.
        // We do this for the seed root (if any); other roots get their legacy
        // refs cleaned the first time `updateRoot` visits them.
        if let root = currentRoot, !root.isEmpty {
            TurnCheckpointStore.deleteLegacySessionRef(workspaceId: session, in: root)
        }
        // Cold start: hydrate baselines persisted from previous sessions so
        // the first turn after a cmux restart shows just that turn's delta
        // instead of falling through to Tier 2 (HEAD diff = everything since
        // initial commit). We merge keeping current in-memory entries (they
        // shouldn't exist yet at start() time, but be defensive about reinit).
        let restored = TurnCheckpointStore.enumerateBaselineTrees(workspaceId: session)
        if !restored.isEmpty {
            baselineTreesByRoot.merge(restored) { current, _ in current }
            // Seed visitedRoots so the multi-repo grouped panel shows every
            // previously-touched repo on cold start, not just the seed root.
            // The active root (if any) belongs at the END so React's
            // default-expand picks it.
            for root in restored.keys {
                guard !root.isEmpty, root != currentRoot else { continue }
                if !visitedRoots.contains(root) {
                    visitedRoots.append(root)
                }
            }
            // Re-append currentRoot last to preserve "most-recent-active at end"
            // ordering, in case it was already present from init.
            if let active = currentRoot, !active.isEmpty,
               let idx = visitedRoots.firstIndex(of: active),
               idx != visitedRoots.count - 1 {
                visitedRoots.remove(at: idx)
                visitedRoots.append(active)
            }
            #if DEBUG
            cmuxDebugLog("turn-diff: baselines hydrated workspace=\(session.uuidString) count=\(restored.count)")
            cmuxDebugLog("turn-diff: hydrated \(restored.count) baselines from disk roots=[\(restored.keys.sorted().joined(separator: ", "))]")
            #endif
        }
        workspace.statusEntriesPublisher
            .map { $0[Self.statusKey]?.value }
            .removeDuplicates()
            .sink { [weak self] value in
                self?.handleStatusTransition(to: value)
            }
            .store(in: &cancellables)
    }

    func stop() {
        stopLiveWatcher()
        cancellables.removeAll()
        // Drop in-memory baselines; nothing on disk in the user's repo to clean.
        baselineTreesByRoot.removeAll()
        // Best-effort: blow away the workspace's diff-state dir so it doesn't
        // accumulate forever. Cheap enough that doing it here beats writing a
        // separate gc routine.
        TurnCheckpointStore.removeDiffStateDirectory(workspaceId: session)
    }

    // MARK: - Root management

    /// Swap the git root used for snapshotting. Pass `nil` to put the manager
    /// idle (focused pane is not inside any repo). `observedCwd` is the pwd we
    /// probed before walking up — passed through to the panel for empty-state UX.
    func updateRoot(to newRoot: String?, observedCwd: String? = nil) {
        // No-op when nothing changed.
        if newRoot == currentRoot {
            return
        }

        // Tear down any in-flight per-turn state tied to the old root.
        // NOTE: do NOT clear the old root's baseline entry — keep it so returning
        // to a previously-visited repo finds its baseline intact (e.g., after a
        // /clear in Claude or hopping between two repos).
        stopLiveWatcher()
        // pendingStartTree was captured against the old root; it is invalid for
        // the new root. Dropping it here is what lets bestEffortDiff fall through
        // to tier 2/3 on the next idle (per spec step 3).
        pendingStartTree = nil

        currentRoot = newRoot
        let hasRoot = (newRoot?.isEmpty == false)
        // Track this root as visited so the multi-repo grouped panel can render
        // every repo we've seen, even after the user hops elsewhere. The
        // most-recently-active root always sits at the END of the array; the
        // React side keys off this for default-expand.
        if hasRoot, let r = newRoot, !r.isEmpty {
            // Best-effort migration: scrub any legacy ref the previous design
            // wrote into the user's .git/refs/cmux/. Idempotent and silent on
            // failure.
            TurnCheckpointStore.deleteLegacySessionRef(workspaceId: session, in: r)

            if let existing = visitedRoots.firstIndex(of: r) {
                if existing != visitedRoots.count - 1 {
                    visitedRoots.remove(at: existing)
                    visitedRoots.append(r)
                }
            } else {
                visitedRoots.append(r)
            }
        }
        #if DEBUG
        cmuxDebugLog("turn-diff: root changed workspace=\(session.uuidString) root=\(newRoot ?? "(nil)") visited=\(visitedRoots.count)")
        #endif
        onRootChanged?(newRoot, hasRoot, observedCwd)

        // Re-emit the full multi-repo diff payload. The newly-active repo's
        // diff for the moment of the swap is whatever bestEffortDiff returns
        // for it (likely empty until the user makes more edits). Previously
        // visited repos still show their last diff so the user retains context.
        emitMultiDiff()

        // Snapshot the new root's working tree as the in-memory baseline ONLY
        // when the agent is idle. If we're currently Running, the root was
        // likely detected via the transcript tailer AFTER Claude already
        // edited a file there — snapshotting now would capture the post-edit
        // state and the diff at running→idle would show nothing. Instead,
        // leave the baseline unset so bestEffortDiff falls through to Tier 2
        // (HEAD diff) and shows uncommitted changes. captureEnd will write a
        // fresh baseline afterward so the next turn produces a clean delta.
        if hasRoot, let root = newRoot, !root.isEmpty, lastStatus != "Running" {
            do {
                let tree = try TurnCheckpointStore.writeTreeIsolated(workspaceId: session, in: root)
                baselineTreesByRoot[root] = tree
                try? TurnCheckpointStore.writeBaselineTree(tree, workspaceId: session, repoRoot: root)
                #if DEBUG
                cmuxDebugLog("turn-diff: baseline cached root=\(root) tree=\(String(tree.prefix(7)))")
                cmuxDebugLog("turn-diff: baseline persisted root=\(root) tree=\(String(tree.prefix(7)))")
                cmuxDebugLog("turn-diff: root changed (idle), baseline saved newRoot=\(root) tree=\(String(tree.prefix(7)))")
                #endif
            } catch {
                #if DEBUG
                cmuxDebugLog("turn-diff: baseline snapshot failed in \(root): \(error)")
                #endif
            }
        } else if hasRoot, lastStatus == "Running" {
            #if DEBUG
            cmuxDebugLog("turn-diff: root changed while running, deferring baseline to captureEnd newRoot=\(newRoot ?? "(nil)")")
            #endif
            // Restart the live watcher in the new root so live updates still
            // fire while the rest of the turn plays out.
            startLiveWatcher()
        }
    }

    // MARK: - State machine

    private func handleStatusTransition(to value: String?) {
        let prev = lastStatus
        lastStatus = value
        onStatusChanged?(value ?? "Unknown")

        switch (prev, value) {
        case (_, "Running"):
            captureStart()
            startLiveWatcher()
        case ("Running", "Idle"):
            stopLiveWatcher()
            captureEnd()
        default:
            break
        }
    }

    private func captureStart() {
        guard let worktree = currentRoot, !worktree.isEmpty else { return }
        do {
            let tree = try TurnCheckpointStore.writeTreeIsolated(workspaceId: session, in: worktree)
            pendingStartTree = tree
            pendingStartRoot = worktree
            // NOTE: do NOT write the baseline here. We commit the pre-turn
            // snapshot as the new baseline only at captureEnd, and only if the
            // turn actually modified this repo (endTree != startTree). That
            // prevents resetting a repo's baseline to "now" when the agent
            // switches roots mid-turn and never actually edits files in this
            // one — which would otherwise make this repo's diff incorrectly
            // show "no changes" instead of preserving its previous turn's delta.
        } catch {
            pendingStartTree = nil
            pendingStartRoot = nil
        }
        #if DEBUG
        cmuxDebugLog("turn-diff: idle->running workspace=\(session.uuidString) root=\(worktree) snapshot=\(pendingStartTree ?? "(nil)")")
        #endif
    }

    private func captureEnd() {
        // Policy: a repo's baseline = "state at the start of that repo's last
        // turn that ACTUALLY MODIFIED IT". So we only commit the pre-turn
        // snapshot (captured at captureStart) as the new baseline if the
        // turn-end tree differs from the turn-start tree for the root that
        // was active at idle→running. That root may differ from `currentRoot`
        // if the agent swapped roots mid-turn (transcript tail detection lags).
        if let pendingRoot = pendingStartRoot,
           !pendingRoot.isEmpty,
           FileManager.default.fileExists(atPath: pendingRoot) {
            do {
                let endTreeForPending = try TurnCheckpointStore.writeTreeIsolated(
                    workspaceId: session,
                    in: pendingRoot
                )
                if let startTree = pendingStartTree, endTreeForPending != startTree {
                    // The turn modified files in pendingRoot. Commit the
                    // pre-turn snapshot as the new baseline so this repo's
                    // diff for the next turn starts from this exact state.
                    baselineTreesByRoot[pendingRoot] = startTree
                    try? TurnCheckpointStore.writeBaselineTree(
                        startTree,
                        workspaceId: session,
                        repoRoot: pendingRoot
                    )
                    #if DEBUG
                    cmuxDebugLog("turn-diff: baseline committed (changed) root=\(pendingRoot) tree=\(String(startTree.prefix(7)))")
                    #endif
                } else {
                    #if DEBUG
                    cmuxDebugLog("turn-diff: baseline unchanged (no work) root=\(pendingRoot)")
                    #endif
                }
            } catch {
                #if DEBUG
                cmuxDebugLog("turn-diff: end-tree probe failed in \(pendingRoot): \(error)")
                #endif
            }
        }

        // First-time fallback for `currentRoot` (which may differ from
        // pendingStartRoot due to a mid-running root swap). If no baseline
        // exists for this repo yet (none in memory and none restored from
        // disk), snapshot now so the NEXT turn produces a clean delta.
        // This turn's diff in currentRoot will fall through to Tier 2 /
        // synthetic, which is acceptable for "never-seen-before" repos.
        if let worktree = currentRoot,
           !worktree.isEmpty,
           baselineTreesByRoot[worktree] == nil {
            do {
                let endTree = try TurnCheckpointStore.writeTreeIsolated(
                    workspaceId: session,
                    in: worktree
                )
                baselineTreesByRoot[worktree] = endTree
                try? TurnCheckpointStore.writeBaselineTree(
                    endTree,
                    workspaceId: session,
                    repoRoot: worktree
                )
                #if DEBUG
                cmuxDebugLog("turn-diff: first-time baseline (no prior state) root=\(worktree) tree=\(String(endTree.prefix(7)))")
                #endif
            } catch {
                #if DEBUG
                cmuxDebugLog("turn-diff: first-time baseline failed in \(worktree): \(error)")
                #endif
            }
        }

        pendingStartTree = nil
        pendingStartRoot = nil

        if let worktree = currentRoot, !worktree.isEmpty {
            let baseline = baselineTreesByRoot[worktree]
            let (diff, tier) = TurnCheckpointStore.bestEffortDiff(
                workspaceId: session,
                baselineTreeSha: baseline,
                in: worktree
            )
            #if DEBUG
            cmuxDebugLog("turn-diff: running->idle workspace=\(session.uuidString) root=\(worktree) diffBytes=\(diff.utf8.count) tier=\(Self.tierLabel(tier))")
            #endif
        }
        // Re-emit the full multi-repo payload so every visited repo's group
        // refreshes on turn end (e.g., the active repo's new diff plus any
        // stale entries for previously-visited repos).
        emitMultiDiff()
    }

    private func startLiveWatcher() {
        guard let cwd = currentRoot, !cwd.isEmpty else { return }
        watcher = WorktreeWatcher(path: cwd) { [weak self] in
            guard let self else { return }
            // Live diff uses the same tiered fallback so a fresh root / bare repo
            // still shows uncommitted edits while the agent is running. Emit the
            // full multi-repo payload so the active repo group updates and any
            // stale-but-still-visible groups for prior repos remain consistent.
            self.emitLiveMultiDiff()
        }
        watcher?.start()
    }

    /// Compute one RepoDiff per visited root and fire the multi-diff callback.
    /// Active repo (matches `currentRoot`) is flagged so the React panel knows
    /// which group to expand by default.
    private func emitMultiDiff() {
        let payload = computeMultiDiff()
        onMultiDiffChanged?(payload)
    }

    /// Live-watcher variant: same payload, dispatched on the live channel so
    /// the React panel can distinguish "turn ended" updates from intra-turn
    /// keystrokes if it wants to (currently both are treated identically).
    private func emitLiveMultiDiff() {
        let payload = computeMultiDiff()
        onLiveMultiDiffChanged?(payload)
    }

    /// Snapshot helper. Used by emitMultiDiff and exposed to the panel host
    /// for the initial load (`.ready` message) so the first paint already has
    /// every repo's diff baked in.
    func computeMultiDiff() -> [RepoDiff] {
        let active = currentRoot
        return visitedRoots.compactMap { root -> RepoDiff? in
            guard !root.isEmpty else { return nil }
            // bestEffortDiff is per-root and stateless; it's safe to call once
            // per visited repo even if no edits have happened there recently —
            // it returns "" and the React side renders an empty group.
            let baseline = baselineTreesByRoot[root]
            let (diff, _) = TurnCheckpointStore.bestEffortDiff(
                workspaceId: session,
                baselineTreeSha: baseline,
                in: root
            )
            return RepoDiff(root: root, diff: diff, isActive: root == active)
        }
    }

    #if DEBUG
    private static func tierLabel(_ tier: TurnCheckpointStore.DiffTier) -> String {
        switch tier {
        case .sessionBaseline: return "1"
        case .head:            return "2"
        case .syntheticAdded:  return "3"
        case .empty:           return "empty"
        }
    }
    #endif

    private func stopLiveWatcher() {
        watcher?.stop()
        watcher = nil
    }
}
