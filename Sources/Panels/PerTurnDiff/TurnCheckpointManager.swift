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
/// Subscribes to claude_code status entry; on idle→running snapshots a
/// pre-turn baseline tree for EVERY visited repo; on running→idle diffs each
/// visited repo's current tree against its pre-turn baseline and caches the
/// resulting diff text only for repos that were actually modified.
///
/// The git root tracked here is dynamic: callers (TurnCheckpointRegistry) update
/// it whenever the focused terminal pane's pwd changes, by walking up to the
/// nearest `.git` ancestor. While `currentRoot == nil` the manager is idle.
///
/// We don't try to predict which repo a prompt will touch. At idle→running we
/// snapshot every visited repo's current state into `pendingPreTurnBaselines`.
/// At running→idle we diff each visited repo's now-state against that pre-turn
/// snapshot. If a repo was modified, we cache its diff in `cachedDiffByRoot`
/// (and persist it). If the diff is empty, we LEAVE the previous cached diff
/// in place so the panel keeps showing that repo's most recent modifying turn.
///
/// All cmux-owned tree/commit objects live under
/// `~/Library/Application Support/cmux/diff-state/...`. No `update-ref` calls
/// are ever made against the user's repo.
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

    /// Per-repo pre-turn baseline tree SHA (cmux store object), keyed by repo
    /// path. Populated at idle→running (or when a new root appears mid-running)
    /// and cleared at running→idle after the diff is computed and cached. While
    /// the agent is idle this dict is empty.
    private var pendingPreTurnBaselines: [String: String] = [:]

    /// Per-repo cached unified-diff text, keyed by repo path. Updated at
    /// running→idle for each repo whose tree changed during the turn; left
    /// AS IS for repos whose tree was unchanged. Persisted to disk so cmux
    /// restarts continue to display each repo's last-modified diff.
    /// This is the source of truth for what we render in the panel.
    private var cachedDiffByRoot: [String: String] = [:]

    /// One root + its rendered diff, for the multi-repo grouped view.
    /// Emitted to the React panel via `onMultiDiffChanged`.
    struct RepoDiff {
        let root: String
        let diff: String
        let isActive: Bool
    }

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
        // Cold start: hydrate per-repo cached diffs persisted from previous
        // sessions so the panel renders each repo's last-modified diff
        // immediately instead of falling through to Tier 2 (HEAD diff). The
        // pre-turn baseline tree concept is now ephemeral (snapshotted per
        // turn), so there's nothing else to restore here.
        let restored = TurnCheckpointStore.enumerateCachedDiffs(workspaceId: session)
        if !restored.isEmpty {
            cachedDiffByRoot.merge(restored) { current, _ in current }
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
            cmuxDebugLog("turn-diff: hydrated \(restored.count) cached diffs for repos=[\(restored.keys.sorted().joined(separator: ", "))]")
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
        // Drop in-memory caches; persisted state is wiped below.
        pendingPreTurnBaselines.removeAll()
        cachedDiffByRoot.removeAll()
        // Best-effort: blow away the workspace's diff-state dir so it doesn't
        // accumulate forever. This also removes per-repo `cached-diff.txt`
        // sidecar files. Cheap enough that doing it here beats writing a
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

        // Tear down any in-flight live watcher tied to the old root.
        // NOTE: do NOT clear cached diffs — the user expects each repo's last
        // modifying-turn diff to remain visible across root hops.
        stopLiveWatcher()

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

        // Re-emit the full multi-repo diff payload using the cached-diff dict.
        // Newly-visited repos with no entry render an empty group; previously
        // visited repos keep their last cached diff so the user retains context.
        emitMultiDiff()

        // If we discover a new root while the agent is Running, snapshot it
        // NOW (best-effort) and add it to pendingPreTurnBaselines so the
        // running→idle diff has a baseline to compare against. Claude may
        // have already edited files here before we noticed (transcript tail
        // detection lags) — snapshotting now is still the best reference
        // point we have. captureEnd's diff will under-report any pre-detection
        // edits, but that's acceptable for the first detection turn.
        if hasRoot,
           let root = newRoot,
           !root.isEmpty,
           lastStatus == "Running",
           pendingPreTurnBaselines[root] == nil {
            do {
                let tree = try TurnCheckpointStore.writeTreeIsolated(workspaceId: session, in: root)
                pendingPreTurnBaselines[root] = tree
                #if DEBUG
                cmuxDebugLog("turn-diff: mid-run baseline snapshot root=\(root) tree=\(String(tree.prefix(7)))")
                #endif
            } catch {
                #if DEBUG
                cmuxDebugLog("turn-diff: mid-run baseline snapshot failed in \(root): \(error)")
                #endif
            }
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
        // We don't know which repo the agent will touch this turn. Snapshot
        // EVERY visited repo's current state as a pre-turn baseline so the
        // diff at running→idle has a reference point for whichever repo (or
        // repos) ends up modified. Per-repo write-tree failures (e.g., dir
        // vanished, permissions) are silently skipped — the running→idle path
        // will fall through to Tier 2 (HEAD diff) for those.
        pendingPreTurnBaselines.removeAll()
        for repo in visitedRoots {
            guard !repo.isEmpty,
                  FileManager.default.fileExists(atPath: repo) else { continue }
            do {
                let tree = try TurnCheckpointStore.writeTreeIsolated(workspaceId: session, in: repo)
                pendingPreTurnBaselines[repo] = tree
            } catch {
                #if DEBUG
                cmuxDebugLog("turn-diff: pre-turn snapshot failed in \(repo): \(error)")
                #endif
                continue
            }
        }
        #if DEBUG
        cmuxDebugLog("turn-diff: idle->running workspace=\(session.uuidString) snapshotted=\(pendingPreTurnBaselines.count)/\(visitedRoots.count)")
        #endif
    }

    private func captureEnd() {
        // For each visited repo, diff its current tree against the pre-turn
        // baseline we snapshotted at captureStart. Three cases:
        //   1. Baseline present + diff non-empty -> repo was modified this
        //      turn. Update cachedDiffByRoot and persist.
        //   2. Baseline present + diff empty -> repo was NOT modified this
        //      turn. LEAVE cachedDiffByRoot[repo] AS IS (preserve previous
        //      turn's display).
        //   3. Baseline missing (first-ever visit, never snapshotted) ->
        //      no reference. Fall through to Tier 2 (git diff HEAD^{tree})
        //      so the user sees uncommitted-vs-HEAD as a best-effort show.
        for repo in visitedRoots {
            guard !repo.isEmpty,
                  FileManager.default.fileExists(atPath: repo) else { continue }
            let baseline = pendingPreTurnBaselines[repo]
            let (diff, tier) = TurnCheckpointStore.bestEffortDiff(
                workspaceId: session,
                baselineTreeSha: baseline,
                in: repo
            )
            if !diff.isEmpty {
                cachedDiffByRoot[repo] = diff
                TurnCheckpointStore.writeCachedDiff(diff, workspaceId: session, repoRoot: repo)
                #if DEBUG
                cmuxDebugLog("turn-diff: cached diff updated repo=\(repo) bytes=\(diff.utf8.count) tier=\(Self.tierLabel(tier))")
                #endif
            } else {
                #if DEBUG
                cmuxDebugLog("turn-diff: turn was no-op for repo=\(repo)")
                #endif
            }
        }

        // Pre-turn baselines are single-turn ephemeral. Wipe them so the next
        // captureStart re-snapshots from a clean slate.
        pendingPreTurnBaselines.removeAll()

        // Re-emit the full multi-repo payload so every visited repo's group
        // refreshes on turn end. The dispatched diffs come straight from the
        // cache so unchanged repos keep their previous turn's display.
        emitMultiDiff()
    }

    private func startLiveWatcher() {
        guard let cwd = currentRoot, !cwd.isEmpty else { return }
        watcher = WorktreeWatcher(path: cwd) { [weak self] in
            guard let self else { return }
            // Live diff for the watched repo uses the SAME pre-turn baseline
            // we'll use at captureEnd, so live updates and the final cached
            // diff agree. Other repos in the payload show their cached diff
            // (stable across turns) so the user retains context.
            self.emitLiveMultiDiff()
        }
        watcher?.start()
    }

    /// Compute one RepoDiff per visited root and fire the multi-diff callback.
    /// Active repo (matches `currentRoot`) is flagged so the React panel knows
    /// which group to expand by default. Diffs come from the cache so other
    /// repos' displays stay stable when this fires between turns.
    private func emitMultiDiff() {
        let payload = computeMultiDiff()
        onMultiDiffChanged?(payload)
    }

    /// Live-watcher variant: dispatched on the live channel during a Running
    /// turn. For the watched repo we recompute from its pendingPreTurnBaseline
    /// so the panel sees in-progress edits in real time; for every other repo
    /// we serve the cached diff (don't churn unrelated groups).
    private func emitLiveMultiDiff() {
        let active = currentRoot
        let payload: [RepoDiff] = visitedRoots.compactMap { root -> RepoDiff? in
            guard !root.isEmpty else { return nil }
            if root == active, let baseline = pendingPreTurnBaselines[root] {
                let (live, _) = TurnCheckpointStore.bestEffortDiff(
                    workspaceId: session,
                    baselineTreeSha: baseline,
                    in: root
                )
                return RepoDiff(root: root, diff: live, isActive: true)
            }
            return RepoDiff(
                root: root,
                diff: cachedDiffByRoot[root] ?? "",
                isActive: root == active
            )
        }
        onLiveMultiDiffChanged?(payload)
    }

    /// Snapshot helper. Used by emitMultiDiff and exposed to the panel host
    /// for the initial load (`.ready` message) so the first paint already has
    /// every repo's diff baked in. Returns the cached diff for each visited
    /// repo — never recomputes from git, so calls between turns are fast and
    /// deterministic.
    func computeMultiDiff() -> [RepoDiff] {
        let active = currentRoot
        return visitedRoots.compactMap { root -> RepoDiff? in
            guard !root.isEmpty else { return nil }
            return RepoDiff(
                root: root,
                diff: cachedDiffByRoot[root] ?? "",
                isActive: root == active
            )
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
