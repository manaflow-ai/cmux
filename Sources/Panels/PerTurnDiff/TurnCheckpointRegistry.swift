import Foundation
import Combine

/// One TurnCheckpointManager + tailer + fallback watcher per active workspace.
/// Lifecycle owned by TabManager via attach/detach calls.
/// Mirrors the pattern of TabManager.wireClosedBrowserTracking.
@MainActor
final class TurnCheckpointRegistry {
    static let shared = TurnCheckpointRegistry()

    private struct Entry {
        let manager: TurnCheckpointManager
        let tailer: ClaudeTranscriptTailer
        let rootDetectionWatcher: WorktreeWatcher?
        var cancellables: Set<AnyCancellable>
    }

    private var entries: [UUID: Entry] = [:]

    private init() {}

    func attach(workspace: Workspace) {
        guard entries[workspace.id] == nil else { return }
        let mgr = TurnCheckpointManager(workspace: workspace)

        // 1) Primary: Claude Code transcript tail. The tailer runs on a
        // background queue; the `onPathDetected` closure is dispatched onto
        // main by the tailer itself, so we can safely call into the @MainActor
        // manager from inside it.
        let tailer = ClaudeTranscriptTailer(
            workspaceCwd: workspace.currentDirectory,
            onPathDetected: { [weak mgr, weak workspace] path in
                MainActor.assumeIsolated {
                    Self.handleCandidatePath(path, manager: mgr, workspace: workspace)
                }
            }
        )
        // Seed the tailer with the workspace's current focused-pane pwd.
        tailer.updateFocusedPanePwd(workspace.focusedPanePwd)

        // 2) Fallback: broad FSEvents watcher rooted at the focused-pane pwd
        // (or the workspace cwd when no pane is focused yet). Whenever any file
        // in that subtree changes we walk back up to find a `.git`. Independent
        // from the per-root WorktreeWatcher used for live diff updates.
        let fallbackRoot: String = {
            if let p = workspace.focusedPanePwd,
               !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return p
            }
            return workspace.currentDirectory
        }()
        var rootDetectionWatcher: WorktreeWatcher?
        let trimmedFallback = fallbackRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallback.isEmpty,
           FileManager.default.fileExists(atPath: trimmedFallback) {
            rootDetectionWatcher = WorktreeWatcher(
                path: trimmedFallback,
                debounceMs: 750
            ) { [weak mgr, weak workspace] in
                // FSEvents debounces onto main already.
                guard let ws = workspace else { return }
                let candidate = ws.focusedPanePwd?.trimmingCharacters(in: .whitespacesAndNewlines)
                let probe = (candidate?.isEmpty == false ? candidate! : ws.currentDirectory)
                Self.handleCandidatePath(probe, manager: mgr, workspace: ws)
            }
            rootDetectionWatcher?.start()
        }

        // Subscribe to focused-pane pwd changes so the tailer always knows
        // which `~/.claude/projects/<sanitized>/` to look at, and so we
        // re-probe `gitRoot(containing:)` whenever the user focuses a
        // terminal in a different repo.
        var cancellables: Set<AnyCancellable> = []
        workspace.$panelDirectories
            .combineLatest(workspace.$focusedPanelIdSignal)
            .sink { [weak tailer, weak mgr, weak workspace] dirs, focusedId in
                let pwd: String? = {
                    if let fid = focusedId, let p = dirs[fid] { return p }
                    return nil
                }()
                tailer?.updateFocusedPanePwd(pwd)
                if let pwd, let mgr {
                    Self.handleCandidatePath(pwd, manager: mgr, workspace: workspace)
                }
            }
            .store(in: &cancellables)

        entries[workspace.id] = Entry(
            manager: mgr,
            tailer: tailer,
            rootDetectionWatcher: rootDetectionWatcher,
            cancellables: cancellables
        )
        mgr.start()
        tailer.start()

        // Seed: try the workspace's current cwd / focused pane pwd as a starting
        // candidate. If either is inside a git repo we jump straight in;
        // otherwise the panel renders its empty state until the tailer or
        // fallback watcher reports something.
        let seed = workspace.focusedPanePwd ?? workspace.currentDirectory
        Self.handleCandidatePath(seed, manager: mgr, workspace: workspace)
    }

    func detach(workspaceId: UUID) {
        guard let entry = entries.removeValue(forKey: workspaceId) else { return }
        entry.tailer.stop()
        entry.rootDetectionWatcher?.stop()
        entry.manager.stop()
    }

    func manager(for workspaceId: UUID) -> TurnCheckpointManager? {
        entries[workspaceId]?.manager
    }

    // MARK: - Candidate path → git root

    /// Walk up from `path` looking for a `.git`. If found and it differs from
    /// the manager's current root, swap in the new root. If not found, leave
    /// the current root as-is (don't blow away an already-detected repo just
    /// because Claude touched something outside of it for one tool call).
    @MainActor
    private static func handleCandidatePath(
        _ path: String?,
        manager: TurnCheckpointManager?,
        workspace: (any TurnCheckpointManagerWorkspace)?
    ) {
        guard let manager else { return }
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No probe path at all → if we never found a root, surface the
            // empty state so the panel can show an actionable message.
            if manager.currentRoot == nil {
                let observed = workspace?.currentDirectory
                manager.updateRoot(to: nil, observedCwd: observed)
            }
            return
        }

        // For files the user/agent referenced, walk from the parent dir.
        // For directories, walk from the dir itself. gitRoot handles both
        // (it just walks parent links until it finds .git).
        let probe: String = {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                return isDir.boolValue ? path : (path as NSString).deletingLastPathComponent
            }
            // Path may not exist yet (e.g. a `Write` to a brand-new file in a
            // brand-new dir). Walk from its parent anyway.
            return (path as NSString).deletingLastPathComponent
        }()

        if let root = TurnCheckpointStore.gitRoot(containing: probe) {
            if root != manager.currentRoot {
                manager.updateRoot(to: root, observedCwd: probe)
            }
        } else if manager.currentRoot == nil {
            // Still no repo. Surface empty state once so the UI updates.
            manager.updateRoot(to: nil, observedCwd: probe)
        }
    }
}
