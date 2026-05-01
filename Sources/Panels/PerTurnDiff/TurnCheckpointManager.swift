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
/// on running→idle compares T_end and updates the ref iff something changed.
///
/// The git root tracked here is dynamic: callers (TurnCheckpointRegistry) update
/// it whenever the focused terminal pane's pwd changes, by walking up to the
/// nearest `.git` ancestor. While `currentRoot == nil` the manager is idle.
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

    /// One root + its rendered diff, for the multi-repo grouped view.
    /// Emitted to the React panel via `onMultiDiffChanged`.
    struct RepoDiff {
        let root: String
        let diff: String
        let isActive: Bool
    }

    /// Cached tree SHA captured at last idle→running. nil while agent is idle.
    private var pendingStartTree: String?

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
        // Cleanup baselines for every repo we ever visited in this session, not
        // just the current one — otherwise stale refs leak across re-attaches.
        for root in visitedRoots where !root.isEmpty {
            try? TurnCheckpointStore.cleanup(session: session, in: root)
        }
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
        // NOTE: do NOT delete the old root's session ref — keep it so returning
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

        // Snapshot the new root's working tree as the baseline ref ONLY when
        // the agent is idle. If we're currently Running, the root was likely
        // detected via the transcript tailer AFTER Claude already edited a
        // file there — snapshotting now would capture the post-edit state and
        // the diff at running→idle would show nothing. Instead, leave the ref
        // unwritten so bestEffortDiff falls through to Tier 2 (HEAD diff) and
        // shows uncommitted changes. captureEnd will write a fresh baseline
        // afterward so the next turn produces a clean delta.
        if hasRoot, let root = newRoot, !root.isEmpty, lastStatus != "Running" {
            do {
                let tree = try TurnCheckpointStore.writeTreeIsolated(in: root)
                let commit = try TurnCheckpointStore.commitTree(
                    tree, parent: nil, message: "cmux baseline on root change", in: root
                )
                try TurnCheckpointStore.updateRef(session: session, commit: commit, in: root)
                #if DEBUG
                let treePrefix = String(tree.prefix(7))
                let commitPrefix = String(commit.prefix(7))
                cmuxDebugLog("turn-diff: root changed (idle), baseline saved newRoot=\(root) tree=\(treePrefix) commit=\(commitPrefix)")
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
            pendingStartTree = try TurnCheckpointStore.writeTreeIsolated(in: worktree)
        } catch {
            pendingStartTree = nil
        }
        #if DEBUG
        cmuxDebugLog("turn-diff: idle->running workspace=\(session.uuidString) root=\(worktree) snapshot=\(pendingStartTree ?? "(nil)")")
        #endif
    }

    private func captureEnd() {
        guard let worktree = currentRoot, !worktree.isEmpty else {
            pendingStartTree = nil
            return
        }

        // Best-effort path: try to commit a clean baseline from the captured
        // T_start tree; if anything fails we still emit the tiered diff so the
        // panel never silently shows "No changes yet." while the working tree
        // has uncommitted changes.
        //
        // The save flow (write-tree → commit-tree → update-ref) is intentionally
        // HEAD-independent: a parent-less commit is fine, and refs/cmux/... can
        // be written even in a brand-new repo with no commits. If HEAD exists we
        // use it as the parent so the snapshot commit slots into history; if
        // not, the commit is parent-less. Either way the session ref is written
        // so the next turn picks Tier 1 instead of falling through to Tier 3
        // (synthetic everything-as-added).
        if let startTree = pendingStartTree {
            do {
                let endTree = try TurnCheckpointStore.writeTreeIsolated(in: worktree)
                if startTree != endTree {
                    let parent: String? = TurnCheckpointStore.refExists("HEAD", in: worktree)
                        ? try? gitHead(in: worktree)
                        : nil
                    let commit = try TurnCheckpointStore.commitTree(
                        startTree, parent: parent, message: "cmux turn base", in: worktree
                    )
                    try TurnCheckpointStore.updateRef(session: session, commit: commit, in: worktree)
                    #if DEBUG
                    let treePrefix = String(startTree.prefix(7))
                    let commitPrefix = String(commit.prefix(7))
                    let refPath = TurnCheckpointStore.refName(for: session)
                    cmuxDebugLog("turn-diff: saved snapshot tree=\(treePrefix) commit=\(commitPrefix) ref=\(refPath)")
                    #endif
                }
            } catch {
                #if DEBUG
                cmuxDebugLog("turn-diff: bestEffortDiff failed in \(worktree): captureEnd ref-update error \(error)")
                #endif
            }
        }
        pendingStartTree = nil

        let (diff, tier) = TurnCheckpointStore.bestEffortDiff(session: session, in: worktree)
        #if DEBUG
        cmuxDebugLog("turn-diff: running->idle workspace=\(session.uuidString) root=\(worktree) diffBytes=\(diff.utf8.count) tier=\(Self.tierLabel(tier))")
        #endif
        // Re-emit the full multi-repo payload so every visited repo's group
        // refreshes on turn end (e.g., the active repo's new diff plus any
        // stale entries for previously-visited repos).
        emitMultiDiff()

        // Always make sure the new root has a baseline ref pointing at the
        // current working tree, so the NEXT turn produces a clean delta even
        // if this turn happened before the root was detected (mid-running
        // updateRoot deferred the baseline to here).
        if !TurnCheckpointStore.refExists(TurnCheckpointStore.refName(for: session), in: worktree) {
            do {
                let endTree = try TurnCheckpointStore.writeTreeIsolated(in: worktree)
                let parent: String? = TurnCheckpointStore.refExists("HEAD", in: worktree)
                    ? try? gitHead(in: worktree)
                    : nil
                let commit = try TurnCheckpointStore.commitTree(
                    endTree, parent: parent, message: "cmux post-turn baseline", in: worktree
                )
                try TurnCheckpointStore.updateRef(session: session, commit: commit, in: worktree)
                #if DEBUG
                cmuxDebugLog("turn-diff: post-turn baseline saved root=\(worktree) tree=\(String(endTree.prefix(7))) commit=\(String(commit.prefix(7)))")
                #endif
            } catch {
                #if DEBUG
                cmuxDebugLog("turn-diff: post-turn baseline failed in \(worktree): \(error)")
                #endif
            }
        }
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
            let (diff, _) = TurnCheckpointStore.bestEffortDiff(session: session, in: root)
            return RepoDiff(root: root, diff: diff, isActive: root == active)
        }
    }

    #if DEBUG
    private static func tierLabel(_ tier: TurnCheckpointStore.DiffTier) -> String {
        switch tier {
        case .sessionRef:     return "1"
        case .head:           return "2"
        case .syntheticAdded: return "3"
        case .empty:          return "empty"
        }
    }
    #endif

    private func stopLiveWatcher() {
        watcher?.stop()
        watcher = nil
    }

    private func gitHead(in worktree: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["rev-parse", "HEAD"]
        p.currentDirectoryURL = URL(fileURLWithPath: worktree)
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
