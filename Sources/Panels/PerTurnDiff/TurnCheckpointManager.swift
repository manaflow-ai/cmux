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

    /// Cached tree SHA captured at last idle→running. nil while agent is idle.
    private var pendingStartTree: String?

    /// Most recent status string seen.
    private var lastStatus: String?

    /// Set by TurnDiffPanelHost; called when the displayed diff should refresh.
    var onDiffChanged: ((String) -> Void)?

    /// Set by TurnDiffPanelHost; called on running/idle state changes.
    var onStatusChanged: ((String) -> Void)?

    /// Set by TurnDiffPanelHost; called when files change mid-turn (debounced via WorktreeWatcher).
    var onLiveDiffChanged: ((String) -> Void)?

    /// Set by TurnDiffPanelHost; fired when the active git root changes.
    /// `(newRoot: String?, hasGitRoot: Bool, observedCwd: String?)`
    /// observedCwd is the focused pane's pwd that was probed (for empty-state copy).
    var onRootChanged: ((String?, Bool, String?) -> Void)?

    private var watcher: WorktreeWatcher?

    init(workspace: any TurnCheckpointManagerWorkspace, currentRoot: String? = nil) {
        self.workspace = workspace
        self.session = workspace.id
        self.currentRoot = currentRoot
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
        if let root = currentRoot, !root.isEmpty {
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
        stopLiveWatcher()
        if let prev = currentRoot, !prev.isEmpty {
            try? TurnCheckpointStore.cleanup(session: session, in: prev)
        }
        // pendingStartTree was captured against the old root; it is invalid for
        // the new root. Dropping it here is what lets bestEffortDiff fall through
        // to tier 2/3 on the next idle (per spec step 3).
        pendingStartTree = nil

        currentRoot = newRoot
        let hasRoot = (newRoot?.isEmpty == false)
        #if DEBUG
        cmuxDebugLog("turn-diff: root changed workspace=\(session.uuidString) root=\(newRoot ?? "(nil)")")
        #endif
        onRootChanged?(newRoot, hasRoot, observedCwd)

        // If the agent happens to be Running while we swap, immediately recapture
        // T_start so the next idle transition produces a meaningful diff.
        if hasRoot, lastStatus == "Running" {
            captureStart()
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
        onDiffChanged?(diff)
    }

    private func startLiveWatcher() {
        guard let cwd = currentRoot, !cwd.isEmpty else { return }
        let sessionId = self.session
        watcher = WorktreeWatcher(path: cwd) { [weak self] in
            guard let self else { return }
            // Live diff uses the same tiered fallback so a fresh root / bare repo
            // still shows uncommitted edits while the agent is running.
            let (diff, _) = TurnCheckpointStore.bestEffortDiff(session: sessionId, in: cwd)
            self.onLiveDiffChanged?(diff)
        }
        watcher?.start()
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
