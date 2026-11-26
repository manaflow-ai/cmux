import CMUXAgentLaunch
import Darwin
import Foundation

/// Keeps a Claude pane's working directory on the Claude session's cwd.
///
/// Shell integration reports the shell's `$PWD`, which cannot change while
/// Claude is the foreground process. `claude --worktree` and Claude's worktree
/// tools move the session into another checkout, and the hook payload's `cwd`
/// is the only report of that move. These helpers send that checkout's root
/// through the same `report_pwd` command shell integration uses, so the
/// sidebar directory and branch, new splits and the Files root all follow it. SessionEnd hands the
/// pane back to the launch directory; the shell also re-reports its `$PWD`
/// at the first prompt after a `claude` command.
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
    /// existing absolute directory.
    ///
    /// Claude's hook cwd also follows every `cd` in its Bash tool, so the pane
    /// follows only a move into another checkout: when the cwd's nearest
    /// checkout root differs from the launch directory's, that root is
    /// reported (`<repo>/.claude/worktrees/wt2` for a session working anywhere
    /// in that worktree). Otherwise the launch directory is reported, in the
    /// shell's spelling, so a `cd` within the launch checkout or a symlinked
    /// path changes nothing.
    private func claudeHookPaneDirectory(hookCwd: String?, launchDirectory: String) -> String? {
        guard let cwd = normalizedHookValue(hookCwd), cwd.hasPrefix("/"),
              let resolvedCwd = resolvedClaudeHookDirectory(cwd) else {
            return nil
        }
        let resolvedLaunch = resolvedClaudeHookDirectory(launchDirectory)
        guard let checkoutRoot = claudeHookCheckoutRoot(containing: resolvedCwd),
              checkoutRoot != resolvedLaunch.flatMap(claudeHookCheckoutRoot(containing:)) else {
            return launchDirectory
        }
        return checkoutRoot
    }

    /// The nearest directory at or above `directory` holding a `.git` entry:
    /// a directory for a main checkout, a file for a linked worktree. Uses
    /// stat only, since hooks run on every turn and must not spawn git.
    private func claudeHookCheckoutRoot(containing directory: String) -> String? {
        var candidate = directory
        while true {
            var info = stat()
            if lstat(candidate + (candidate == "/" ? ".git" : "/.git"), &info) == 0 {
                return candidate
            }
            guard candidate != "/" else { return nil }
            let parent = (candidate as NSString).deletingLastPathComponent
            candidate = parent.isEmpty ? "/" : parent
        }
    }

    /// The physical path of an existing directory, or nil.
    private func resolvedClaudeHookDirectory(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let resolvedPath = String(cString: resolved)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return resolvedPath
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
