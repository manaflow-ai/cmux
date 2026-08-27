import AppKit
import Foundation

/// One shared path for "give me a coding agent that knows cmux Cloud".
///
/// The Machines panel menu launches a local terminal running the chosen agent
/// with a kickoff prompt, and "Copy Cloud Prompt" puts the same prompt on the
/// clipboard for any other terminal. Both first install the bundled skill file
/// at a stable path under `~/.config/cmux/skills/` so the prompt's file
/// reference resolves for any agent, with no network access.
enum CloudAgentSkillLauncher {
    /// Agents the launcher can start locally. Raw values are the executable
    /// names resolved through the user's login shell PATH.
    enum CodingAgent: String, CaseIterable {
        case claude
        case codex
        case opencode

        var displayName: String {
            switch self {
            case .claude:
                return String(localized: "machines.agent.claude", defaultValue: "Claude Code")
            case .codex:
                return String(localized: "machines.agent.codex", defaultValue: "Codex")
            case .opencode:
                return String(localized: "machines.agent.opencode", defaultValue: "OpenCode")
            }
        }

        /// Interactive-session argv carrying the kickoff prompt. claude and
        /// codex take a positional initial prompt; opencode uses `--prompt`.
        func argv(prompt: String) -> [String] {
            switch self {
            case .claude: return ["claude", prompt]
            case .codex: return ["codex", prompt]
            case .opencode: return ["opencode", "--prompt", prompt]
            }
        }
    }

    enum LauncherError: LocalizedError {
        case skillResourceMissing
        case noSelectedWorkspace

        var errorDescription: String? {
            switch self {
            case .skillResourceMissing:
                return String(
                    localized: "machines.agent.error.missingSkill",
                    defaultValue: "This build is missing the bundled cmux Cloud skill file."
                )
            case .noSelectedWorkspace:
                return String(
                    localized: "machines.agent.error.noWorkspace",
                    defaultValue: "Open a workspace first, then start the cloud agent."
                )
            }
        }
    }

    static let installedSkillRelativePath = ".config/cmux/skills/cmux-cloud.md"

    /// The bundled skill markdown (`Resources/cloud-agent-skill.md`).
    static func skillMarkdown(bundle: Bundle = .main) -> String? {
        let url = bundle.url(forResource: "cloud-agent-skill", withExtension: "md")
            ?? bundle.resourceURL?.appendingPathComponent("cloud-agent-skill.md")
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Writes the bundled skill to the stable per-user path and returns it.
    /// Regenerated on every use so the file always matches the running app;
    /// the file's own header says it is managed and not to hand-edit it.
    @discardableResult
    static func installSkillFile(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundle: Bundle = .main
    ) throws -> URL {
        guard let markdown = skillMarkdown(bundle: bundle) else {
            throw LauncherError.skillResourceMissing
        }
        let url = homeDirectory.appendingPathComponent(installedSkillRelativePath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(markdown.utf8).write(to: url, options: .atomic)
        return url
    }

    /// The kickoff prompt. Deliberately not localized: it is agent input, not
    /// UI copy, and the skill file it points at is English.
    static func kickoffPrompt(skillPath: String) -> String {
        """
        Read \(skillPath) before doing anything else. It explains how to work \
        with my cmux Cloud machines through the `cmux` CLI (`cmux vm ...`); when \
        it disagrees with the CLI, `cmux vm <subcommand> --help` wins. Start by \
        running `cmux vm ls`, summarize my machines in one line each, and ask \
        what I want to do.
        """
    }

    /// The full shell command for a terminal pane running `agent`.
    static func shellCommand(agent: CodingAgent, prompt: String) -> String {
        agent.argv(prompt: prompt)
            .map(SurfaceResumeCommandCanonicalizer.shellQuoted)
            .joined(separator: " ")
    }

    /// Installs the skill file and opens a local terminal pane in the selected
    /// workspace running the agent with the kickoff prompt.
    @MainActor
    static func openAgent(
        _ agent: CodingAgent,
        selectedWorkspaceID: UUID? = AppDelegate.shared?.tabManager?.selectedTabId
    ) throws {
        let skillURL = try installSkillFile()
        guard let workspaceID = selectedWorkspaceID else {
            throw LauncherError.noSelectedWorkspace
        }
        let command = shellCommand(agent: agent, prompt: kickoffPrompt(skillPath: skillURL.path))
        _ = try SurfacePaneFactory.makeTerminalPane(
            initialCommand: command,
            workingDirectory: nil,
            at: .workspace(id: workspaceID, placement: .split),
            focus: true
        )
    }

    /// Installs the skill file and puts the kickoff prompt on the clipboard.
    @MainActor
    static func copyPrompt() throws {
        let skillURL = try installSkillFile()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(kickoffPrompt(skillPath: skillURL.path), forType: .string)
    }
}
