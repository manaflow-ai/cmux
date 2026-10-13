import CMUXAgentLaunch
import Darwin
import Foundation

/// Keeps a Claude pane's working directory on the Claude session's cwd.
///
/// Shell integration reports the shell's `$PWD`, which cannot change while
/// Claude is the foreground process. `claude --worktree` and Claude's worktree
/// tools move the session into another checkout, and the hook payload's `cwd`
/// is the only report of that move. These helpers send it through the same
/// `report_pwd` command shell integration uses, so the sidebar directory and
/// branch, new splits and the Files root all follow it. SessionEnd hands the
/// pane back to the launch directory, because the shell re-reports only a
/// directory it has not already sent.
extension CMUXCLI {
    /// Reports a Claude hook's session cwd as the pane's working directory.
    ///
    /// Sends nothing for a missing, relative or nonexistent cwd, or when the
    /// cmux Claude wrapper did not record the launch directory: without it,
    /// SessionEnd could not hand the pane back to the shell.
    func reportClaudeHookPaneDirectory(
        hookCwd: String?,
        workspaceId: String,
        surfaceId: String,
        client: SocketClient
    ) {
        guard let launchDirectory = claudeHookLaunchDirectory(),
              let directory = claudeHookPaneDirectory(
                  hookCwd: hookCwd,
                  launchDirectory: launchDirectory
              ) else {
            return
        }
        sendClaudeHookPaneDirectory(
            directory,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            client: client
        )
    }

    /// Reports the directory the wrapper launched Claude from, which is the
    /// shell's own `$PWD` once Claude exits.
    func restoreClaudeLaunchPaneDirectory(
        workspaceId: String,
        surfaceId: String,
        client: SocketClient
    ) {
        guard let launchDirectory = claudeHookLaunchDirectory() else { return }
        sendClaudeHookPaneDirectory(
            launchDirectory,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            client: client
        )
    }

    /// The launch directory the cmux Claude wrapper exported, when it
    /// describes a Claude launch. `CMUX_AGENT_LAUNCH_*` leaks to descendant
    /// processes, so another agent's capture is not this session's.
    private func claudeHookLaunchDirectory() -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard let launcher = normalizedHookValue(environment["CMUX_AGENT_LAUNCH_KIND"]),
              AgentLaunchCaptureTrust.launcherDescribesKind(launcher, kind: "claude"),
              let directory = normalizedHookValue(environment["CMUX_AGENT_LAUNCH_CWD"]),
              directory.hasPrefix("/") else {
            return nil
        }
        return directory
    }

    /// The directory to report for a hook cwd, or nil when the cwd is not an
    /// existing absolute directory. The launch directory keeps the shell's
    /// spelling, so a symlinked checkout does not flip to its physical path
    /// whenever Claude reports it.
    private func claudeHookPaneDirectory(hookCwd: String?, launchDirectory: String) -> String? {
        guard let cwd = normalizedHookValue(hookCwd), cwd.hasPrefix("/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        if let resolvedCwd = resolvedClaudeHookDirectory(cwd),
           resolvedCwd == resolvedClaudeHookDirectory(launchDirectory) {
            return launchDirectory
        }
        return cwd
    }

    private func resolvedClaudeHookDirectory(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func sendClaudeHookPaneDirectory(
        _ directory: String,
        workspaceId: String,
        surfaceId: String,
        client: SocketClient
    ) {
        let panelOption = socketPanelOption(surfaceId)
        // Without a panel, report_pwd falls back to the focused surface,
        // which is not necessarily the pane Claude runs in.
        guard !panelOption.isEmpty else { return }
        _ = try? sendV1Command(
            "report_pwd \(socketQuote(directory)) --tab=\(workspaceId)\(panelOption)",
            client: client
        )
    }
}
