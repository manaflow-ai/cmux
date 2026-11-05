import CmuxNextActions
import CmuxNextAppCore
import CmuxNextPages

/// Projection windows (``WebProjection``, CmuxNextPages; HQ#7149 L10): opens the window a projection
/// names with a terminal in its worktree, and runs its test in a new workspace there, kept open.
enum ProjectionWindows {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let services = context.services, projection = WebProjection.shared
        projection.windowID = { [weak services] in services?.windows.owner(of: $0)?.state.id }
        projection.isOpen = { [weak services] in services?.windows.controller(for: $0) != nil }
        registry.bindEffect(ActionID(rawValue: WebProjection.openID), unavailable: { WebProjection.unavailableReason }) { [weak services] invocation in
            do throws(WebProjection.Refusal) {
                let opened = try projection.open(server: invocation["server"]?.stringValue, worktree: invocation["worktree"]?.stringValue,
                                                 test: invocation["test"]?.stringValue)
                var spawn = WorkspaceSpawn(cwd: opened.worktree, name: WebProjection.workspaceName(opened.worktree))
                spawn.opensNewTabPage = true
                services?.windows.startDetached(spawn, into: opened.windowID)
                return .done
            } catch { return .refused(error.message) }
        }
        registry.bindEffect(ActionID(rawValue: WebProjection.runTestID), unavailable: { WebProjection.unavailableReason }) { [weak services] invocation in
            do throws(WebProjection.Refusal) {
                let run = try projection.testRun(in: services?.windows.active?.state.id, test: invocation["test"]?.stringValue)
                services?.windows.startDetached(WorkspaceSpawn(cwd: run.worktree, name: WebProjection.testName, command: run.test, keep: true),
                                                into: run.windowID)
                return .done
            } catch { return .refused(error.message) }
        }
    }
}

extension WindowManager {
    /// Starts a workspace create whose daemon part nobody waits for (``startWorkspace(_:on:into:frame:)``).
    fileprivate func startDetached(_ spawn: WorkspaceSpawn, into windowID: String) {
        let create = startWorkspace(spawn, into: windowID)
        Task { _ = try? await create() } // task-owner: the create's daemon part; its window shows when the daemon lists it
    }
}
