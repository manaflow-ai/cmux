import Foundation

extension CMUXCLI {
    /// Guides are handled before socket discovery, authentication, and window focus.
    /// Only these command positions belong to cmux; an agent or exec payload can
    /// contain `--skill` without being intercepted.
    func runGuideCommand(command: String, commandArgs: [String], jsonOutput: Bool) throws -> Bool {
        let cloud: Bool
        let remaining: [String]
        switch command {
        case "guide", "--skill":
            cloud = false
            remaining = commandArgs
        case "cloud", "vm":
            guard ["guide", "--skill"].contains(commandArgs.first ?? "") else { return false }
            cloud = true
            remaining = Array(commandArgs.dropFirst())
        default:
            return false
        }

        let invocation = cloud ? "cmux cloud guide | cmux cloud --skill" : "cmux guide | cmux --skill"
        let usage = "Usage: \(invocation) [--json]\n\n" + Self.guideDescription
        if remaining == ["--help"] || remaining == ["-h"] {
            print(usage)
            return true
        }
        guard remaining.isEmpty else {
            throw CLIError(message: usage, exitCode: 2)
        }

        let content = cloud ? Self.cloudGuide : Self.overviewGuide
        if jsonOutput {
            print(jsonString(["topic": cloud ? "cloud" : "cmux", "format": "markdown", "content": content]))
        } else {
            print(content)
        }
        return true
    }

    static var guideDescription: String {
        CMUXDiffViewerLocalization.string(
            "cli.guide.description",
            defaultValue: "Read a short guide and find specific methods. No running app, network access, or sign-in is needed to read it."
        )
    }

    static var overviewGuide: String {
        """
        # cmux guide

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.intro", defaultValue: "cmux puts terminals, browsers, and agents in one workspace. Use this guide to choose a method, then read its help before acting. `cmux --skill` prints this same guide."))

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.targets", defaultValue: "## Find your target\n\nA window contains workspaces. A workspace contains split panes. Each pane contains surfaces, such as a terminal or browser tab. Inspect the caller and use the returned IDs. Keep the caller's workspace and surface context; use explicit targets and `--focus false` where supported."))

        ```sh
        cmux identify --json
        cmux tree --all --json
        cmux capabilities --json
        ```

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.terminals", defaultValue: "## Work with terminals\n\nCreate a workspace for a task, add panes for parallel work, and read terminal output before sending input. `send` enters text; `send-key` sends keys. Read the screen again to check the result."))

        `cmux new-workspace --help` · `cmux new-pane --help`
        `cmux read-screen --help` · `cmux send --help` · `cmux send-key --help`

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.browser", defaultValue: "## Use a browser\n\nUse `cmux browser` for a browser surface inside cmux. Use `agent-browser` for a separate browser session. Prefer an existing headful Chrome session when it exposes DevTools through remote debugging: `agent-browser --auto-connect snapshot`, or `agent-browser --cdp 9222 snapshot` for an explicit port. A normal Chrome window without remote debugging cannot be attached; `agent-browser --headed` starts a new visible browser. Read a snapshot, act on an observed element, then take a fresh snapshot. Check appearance with a screenshot. Keep each tool's target IDs within that tool."))

        ```sh
        cmux browser open https://example.com --focus false
        cmux browser --surface <surface> snapshot --interactive
        cmux browser --help
        agent-browser --auto-connect snapshot
        agent-browser --cdp 9222 snapshot
        agent-browser --headed open https://example.com
        agent-browser --help
        ```

        [cmux browser](https://cmux.com/docs/browser-automation) · [agent-browser docs](https://agent-browser.dev/) · [agent-browser commands](https://agent-browser.dev/commands)

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.computer", defaultValue: "## Use app windows\n\nUse computer-use tools for native apps or visual controls. cmux provides these tools to Claude Code and Codex sessions launched in cmux. Complete setup in Settings > Computer Use. Read the `cmux-cua` skill for your agent's methods: inspect app or window state, click or type, then inspect again."))

        [cmux-cua](https://github.com/manaflow-ai/cmux/blob/main/skills/cmux-cua/SKILL.md#using-the-tools-agent-facing)

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.cloud", defaultValue: "## Use Cloud\n\nUse cmux Cloud when work needs a remote machine. List machines before choosing one. Use `exec` for a short command, `agent` for a coding agent, and `push` or `pull` for files. The default Cloud devbox includes Chrome and `cua-driver`; the Cloud guide explains how to verify and use them. Use the Cloud guide for desktop, browser, port, and machine lifecycle methods."))

        ```sh
        cmux cloud ls --json
        cmux cloud exec <machine> -- pwd
        cmux cloud agent --help
        cmux cloud guide
        ```

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.share", defaultValue: "## Show work and find more methods\n\nUse Markdown and diff views to show results. Use notifications and progress to report task state. Read the Cloud guide for remote machines. Settings and integration docs list their own methods."))

        `cmux markdown --help` · `cmux diff --help` · `cmux notify --help` · `cmux set-progress --help`
        `cmux cloud guide` · `cmux docs settings` · `cmux docs agents` · `cmux docs api`
        """
    }

    static var cloudGuide: String {
        """
        # cmux cloud guide

        \(CMUXDiffViewerLocalization.string("cli.guide.cloud.intro", defaultValue: "cmux Cloud runs commands, agents, browsers, and desktops on remote machines. Run the commands below from cmux on your Mac. Cloud operations need the app and a signed-in account. `cmux cloud --skill` prints this same guide; `cmux vm` is an alias for `cmux cloud`."))

        \(CMUXDiffViewerLocalization.string("cli.guide.cloud.choose", defaultValue: "## Choose a machine\n\nInspect existing machines first. Base is a persistent workspace that you can reopen. Use `new` when the task needs a separate machine. Use returned machine, workspace, and terminal IDs in later commands."))

        ```sh
        cmux auth status
        cmux cloud ls --json
        cmux cloud tree --json
        cmux cloud base --help
        cmux cloud new --help
        ```

        \(CMUXDiffViewerLocalization.string("cli.guide.cloud.work", defaultValue: "## Run work and collect results\n\nUse `exec` for a short command on a chosen machine. Use `run` to route a command, or `agent` to start a coding agent. Use `push` and `pull` to transfer files. Use `terminal` methods to send input, read output, or wait for completion."))

        ```sh
        cmux cloud exec <machine> -- pwd
        cmux cloud run --help
        cmux cloud agent --help
        cmux cloud terminal --help
        cmux cloud push --help
        cmux cloud pull --help
        ```

        \(CMUXDiffViewerLocalization.string("cli.guide.cloud.browser", defaultValue: "## Use browsers and computer use\n\nFor browser automation on the machine, run `agent-browser` there and read its documentation. Prefer the machine's existing headful Chrome session when it exposes DevTools. The devbox installs Chrome, but its dock launcher does not enable remote debugging by default. Start a debugging-enabled Chrome with `--remote-debugging-port=9222`, then use `agent-browser --cdp 9222 snapshot`, or try `agent-browser --auto-connect snapshot`. Inspect installed tools with `tools` first. The default devbox also installs `cua-driver` for Linux desktop automation. Verify it with `cua-driver --version` and `cua-driver doctor`; it needs the desktop display (`DISPLAY=:1`) and accessibility bus. Use `cua-driver` for visible desktop windows and `agent-browser` for web pages. Historical shell-only machines may not have a desktop or driver. Inspect the remote screen, act, then verify. Local computer-use tools target your Mac unless configured for a remote target."))

        ```sh
        cmux cloud tools <machine>
        cmux cloud exec <machine> -- agent-browser --help
        cmux cloud exec <machine> -- agent-browser --auto-connect snapshot
        cmux cloud exec <machine> -- cua-driver --version
        cmux cloud exec <machine> -- cua-driver doctor
        cmux cloud desktop <machine>
        ```

        [agent-browser docs](https://agent-browser.dev/) · [agent-browser commands](https://agent-browser.dev/commands) · [cmux cloud agent](https://github.com/manaflow-ai/cmux/blob/main/skills/cmux-cloud-vm/references/agent-workflows.md)

        \(CMUXDiffViewerLocalization.string("cli.guide.cloud.share", defaultValue: "## Open, share, and keep work\n\nUse `open` for a machine's terminal, desktop, or web port. Private web URLs need the Cloud network connection; read `vpn` help. Use `domains` to publish a web port with explicit access rules. Use snapshots and forks to keep or copy machine state. Removing a machine deletes it."))

        `cmux cloud open --help` · `cmux vpn --help` · `cmux cloud domains --help`
        `cmux cloud snapshot --help` · `cmux cloud fork --help` · `cmux cloud rm --help`

        \(CMUXDiffViewerLocalization.string("cli.guide.cloud.more", defaultValue: "## Find exact methods\n\nRead command help for flags and examples. The full Cloud reference covers machine lifecycle, workspaces, terminals, and transfers. Use `cmux guide` for local workspace, browser, and computer-use methods."))

        `cmux cloud --help` · `cmux cloud <command> --help` · `cmux guide`
        [cmux cloud](https://github.com/manaflow-ai/cmux/blob/main/skills/cmux-cloud-vm/references/commands.md)
        """
    }
}
