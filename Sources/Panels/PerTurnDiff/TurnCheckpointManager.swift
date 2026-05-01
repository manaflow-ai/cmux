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
        pendingStartTree = nil

        currentRoot = newRoot
        let hasRoot = (newRoot?.isEmpty == false)
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
    }

    private func captureEnd() {
        guard let worktree = currentRoot, !worktree.isEmpty,
              let startTree = pendingStartTree else {
            pendingStartTree = nil
            return
        }
        defer { pendingStartTree = nil }

        do {
            let endTree = try TurnCheckpointStore.writeTreeIsolated(in: worktree)
            guard startTree != endTree else {
                // No-op turn: no ref update, no diff change.
                return
            }
            let head = try gitHead(in: worktree)
            let commit = try TurnCheckpointStore.commitTree(
                startTree, parent: head, message: "cmux turn base", in: worktree
            )
            try TurnCheckpointStore.updateRef(session: session, commit: commit, in: worktree)
            let diff = try TurnCheckpointStore.diffAgainstWorkingTree(session: session, in: worktree)
            onDiffChanged?(diff)
        } catch {
            // Snapshot or diff failed; surface via status only, don't crash.
        }
    }

    private func startLiveWatcher() {
        guard let cwd = currentRoot, !cwd.isEmpty else { return }
        let sessionId = self.session
        watcher = WorktreeWatcher(path: cwd) { [weak self] in
            guard let self else { return }
            // Live diff requires a current last-turn-base ref; if missing (very first turn
            // ever with no completed code-change yet), this returns "" — UI shows empty state.
            let diff = (try? TurnCheckpointStore.diffAgainstWorkingTree(
                session: sessionId, in: cwd
            )) ?? ""
            self.onLiveDiffChanged?(diff)
        }
        watcher?.start()
    }

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
