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
    /// APPEND-ONLY: a root is added to the end the FIRST time it's seen and
    /// never moved on subsequent visits. The React panel relies on this
    /// stable ordering so the active repo doesn't shuffle to the bottom of
    /// the list every time the agent switches focus. The user can manually
    /// reorder repo groups in the panel; the panel persists that order
    /// independently in localStorage.
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

    /// Absolute file paths the agent transcript reported during the in-flight
    /// turn. Cleared at idle→running, populated by `recordDetectedPath` while
    /// running, consumed at running→idle. Used to scope the first-fetch diff
    /// for repos with no baseline (so we show only what Claude touched this
    /// turn, not the entire pre-existing dirty state).
    private var thisTurnDetectedPaths: Set<String> = []

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
            // Route through the helper so a worktree seed picks up its parent.
            appendVisitedRoot(root)
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
        Self.runOneShotDiffStatePurgeIfNeeded(forWorkspace: session)
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
            // APPEND-ONLY: keep insertion order stable. The seed root (if any)
            // already sits at index 0 from init; restored roots are appended
            // afterwards in dictionary-iteration order.
            for root in restored.keys {
                guard !root.isEmpty, root != currentRoot else { continue }
                appendVisitedRoot(root)
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
        thisTurnDetectedPaths.removeAll()
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
        // every repo we've seen, even after the user hops elsewhere.
        // APPEND-ONLY: a root joins the array the first time we see it and
        // never moves on subsequent visits. This keeps the React panel's
        // default ordering stable so focus changes don't reshuffle the list;
        // the panel layers manual drag-to-reorder on top of this order.
        if hasRoot, let r = newRoot, !r.isEmpty {
            // Best-effort migration: scrub any legacy ref the previous design
            // wrote into the user's .git/refs/cmux/. Idempotent and silent on
            // failure.
            TurnCheckpointStore.deleteLegacySessionRef(workspaceId: session, in: r)

            appendVisitedRoot(r)
        }
        #if DEBUG
        cmuxDebugLog("turn-diff: root changed workspace=\(session.uuidString) root=\(newRoot ?? "(nil)") visited=\(visitedRoots.count)")
        #endif
        onRootChanged?(newRoot, hasRoot, observedCwd)

        // Re-emit the full multi-repo diff payload using the cached-diff dict.
        // Newly-visited repos with no entry render an empty group; previously
        // visited repos keep their last cached diff so the user retains context.
        emitMultiDiff()

        // If we discover a new root while the agent is Running, do NOT snapshot
        // it now — Claude has likely already edited files there (transcript tail
        // detection lags), so the snapshot would equal the post-edit state and
        // the diff at running→idle would be empty. Instead leave
        // pendingPreTurnBaselines[root] = nil so bestEffortDiff falls through to
        // Tier 2 (HEAD diff), which approximately equals "this turn's edits"
        // when the repo was clean before. Just restart the live watcher so live
        // updates fire for the rest of the turn.
        if hasRoot, let root = newRoot, !root.isEmpty, lastStatus == "Running" {
            #if DEBUG
            cmuxDebugLog("turn-diff: mid-run root detected root=\(root), deferring baseline to Tier 2 fallback")
            #endif
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

    /// Called by the registry from the transcript tailer's onPathDetected
    /// closure (already on the main actor). Builds up the per-turn set of
    /// paths the agent touched so captureEnd can scope first-fetch diffs to
    /// just those files for repos that had no baseline.
    func recordDetectedPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        thisTurnDetectedPaths.insert(trimmed)
    }

    /// Called by the registry from the PreToolUse hook handler after the
    /// socket handler has done the synchronous git work off-main. Stores the
    /// already-computed snapshot so captureEnd can diff against it. `repo`
    /// and `tree` may be nil if the path didn't resolve to a git root or the
    /// snapshot failed — we still record the path so captureEnd's scoped-diff
    /// fallback can use it. Earliest snapshot per (repo, turn) wins.
    func recordPreEditSnapshot(path: String, repo: String?, tree: String?) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        thisTurnDetectedPaths.insert(trimmed)

        guard let repo, !repo.isEmpty else { return }
        appendVisitedRoot(repo)

        guard let tree, !tree.isEmpty else { return }
        if pendingPreTurnBaselines[repo] != nil { return }
        pendingPreTurnBaselines[repo] = tree
    }

    /// Snapshot every visited repo's current tree as a pre-turn baseline.
    /// PreToolUse hooks may have already filled in baselines for some repos
    /// (the more accurate path); we preserve those and only fill in the gaps.
    /// Note: this runs synchronously on the main actor and blocks while
    /// `git write-tree` runs per repo. For typical workspaces (1-3 repos)
    /// this completes within a few hundred ms; large multi-repo workspaces
    /// may want a follow-up that moves git I/O onto a serialized background
    /// queue with proper ordering against captureEnd.
    private func captureStart() {
        for repo in visitedRoots {
            guard !repo.isEmpty,
                  FileManager.default.fileExists(atPath: repo) else { continue }
            if pendingPreTurnBaselines[repo] != nil { continue }
            if let tree = try? TurnCheckpointStore.writeTreeIsolated(workspaceId: session, in: repo) {
                pendingPreTurnBaselines[repo] = tree
            }
        }
    }

    /// Diff every visited repo's current tree against its per-repo pre-turn
    /// baseline. Four cases per repo:
    ///   1. Baseline + non-empty diff → repo was modified; update cache.
    ///   2. Baseline + empty diff → repo unchanged; preserve previous cache.
    ///   3. No baseline + transcript-detected paths inside repo → scoped
    ///      `git diff HEAD -- <paths>` so we don't surface pre-existing dirt.
    ///   4. Otherwise → Tier 2/3 fallback (HEAD diff or synthetic added).
    private func captureEnd() {
        for repo in visitedRoots {
            guard !repo.isEmpty,
                  FileManager.default.fileExists(atPath: repo) else { continue }
            let baseline = pendingPreTurnBaselines[repo]

            if baseline == nil {
                let scopedPaths = Self.pathsInside(repo: repo, from: thisTurnDetectedPaths)
                if !scopedPaths.isEmpty,
                   let scoped = try? TurnCheckpointStore.scopedDiff(
                        workspaceId: session,
                        in: repo,
                        paths: scopedPaths
                   ),
                   !scoped.isEmpty {
                    cachedDiffByRoot[repo] = scoped
                    TurnCheckpointStore.writeCachedDiff(scoped, workspaceId: session, repoRoot: repo)
                    continue
                }
            }

            let (diff, _) = TurnCheckpointStore.bestEffortDiff(
                workspaceId: session,
                baselineTreeSha: baseline,
                in: repo
            )
            if !diff.isEmpty {
                cachedDiffByRoot[repo] = diff
                TurnCheckpointStore.writeCachedDiff(diff, workspaceId: session, repoRoot: repo)
            }
        }

        pendingPreTurnBaselines.removeAll()
        thisTurnDetectedPaths.removeAll()
        emitMultiDiff()
    }

    /// Filter `paths` down to those that live inside `repo`. Both sides are
    /// expected to be absolute. Uses a simple prefix check normalised to a
    /// trailing slash so that `/foo` doesn't accidentally match `/foobar`.
    nonisolated private static func pathsInside(repo: String, from paths: Set<String>) -> [String] {
        let trimmed = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let prefix = trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
        var out: [String] = []
        for p in paths {
            if p == trimmed || p.hasPrefix(prefix) {
                out.append(p)
            }
        }
        return out
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

    /// Append `root` to `visitedRoots` (idempotent). The append-only invariant
    /// keeps the React panel's default ordering stable — see `visitedRoots`
    /// docs.
    @discardableResult
    private func appendVisitedRoot(_ root: String) -> Bool {
        guard !root.isEmpty, !visitedRoots.contains(root) else { return false }
        visitedRoots.append(root)
        return true
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

    // MARK: - One-shot v2 migration

    /// Process-wide UserDefaults key that records that we already wiped the
    /// diff-state directory tree for a previous bug. Bump the version suffix
    /// when shipping a new fix that requires a fresh purge — every install
    /// then runs the purge once on first workspace attach after upgrading.
    /// v2 wiped state from the buggy "newest jsonl by mtime" identification.
    /// v3 wipes state from a regression where missing sessionId briefly fell
    /// back to mtime, admitting external Claude sessions into cmux workspaces.
    private static let migrationFlagKey = "cmux.perTurnDiff.migration.v3.done"

    /// Run a one-shot purge of THIS workspace's diff-state dir (per spec) so
    /// any ghost entries captured under previous bugs are wiped FOR ALL
    /// workspaces. Sets the flag after the first call so the purge fires
    /// once per install per migration version (see `migrationFlagKey`).
    /// Per-workspace scoping would only clean whichever workspace happened
    /// to attach first, leaving the rest with stale state.
    private static func runOneShotDiffStatePurgeIfNeeded(forWorkspace _: UUID) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationFlagKey) else { return }
        TurnCheckpointStore.removeAllDiffState()
        defaults.set(true, forKey: migrationFlagKey)
    }
}
