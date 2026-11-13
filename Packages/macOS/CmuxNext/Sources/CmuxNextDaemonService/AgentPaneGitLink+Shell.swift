public import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// Shell mode of a chat on this link's machine: the machine's daemon runs, reads and stops the
/// command (`shell-runs-v1`, cmux-tui `shell_runs.rs`). The read's long poll waits on the daemon's
/// own thread, so the link's other requests are not held behind it.
extension AgentPaneGitLink: AgentPaneMachineShell {
    static let shellRequestTimeout: Duration = .seconds(10)

    /// The id is chosen here: a start whose answer never comes (a stalled link) is stopped
    /// under it, so the command does not keep running with no pane that can stop it.
    public func runShell(_ command: String, cwd: String?, scope: String) async throws -> String {
        let id = ShellRunRequest.newRunID()
        let answer: ShellRunRequest.Response
        do {
            answer = try await request(ShellRunRequest(command: command, cwd: cwd, scope: scope, run: id), timeout: Self.shellRequestTimeout)
        } catch {
            await stopShell(id)
            throw error
        }
        guard let run = answer.run else { throw Self.shellFailure(answer.refused) }
        return run
    }

    public func readShell(_ id: String, after: Int) async throws -> AgentPaneShell.Chunk {
        let answer = try await request(ShellReadRequest(run: id, after: after), timeout: ShellReadRequest.timeout)
        guard answer.refused == nil, let next = answer.next else { throw Self.shellFailure(answer.refused) }
        return AgentPaneShell.Chunk(
            output: answer.output ?? "",
            next: next,
            truncated: answer.truncated == true,
            exit: answer.exit.map { AgentPaneShell.Exit(code: $0.code, signal: $0.signal) })
    }

    public func stopShell(_ id: String) async {
        _ = try? await request(ShellStopRequest(run: id), timeout: Self.shellRequestTimeout)
    }

    /// The daemon's refusal code as the pane's own failure (its message).
    static func shellFailure(_ code: String?) -> AgentPaneShell.Failure {
        switch code {
        case "too_many": .tooMany
        case "folder_missing": .folderMissing
        case "unknown_run": .unknownRun
        default: .spawnFailed(0)
        }
    }
}
