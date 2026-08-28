import AppKit
import Foundation

/// One shared path for "give me a coding agent that knows cmux Cloud".
///
/// The Machines panel menu and the `vm.cloud_agent_open` socket method both
/// launch a local terminal through `TerminalController.surfaceNewTerminal`
/// running the chosen agent with a kickoff prompt; "Copy Cloud Prompt" and
/// `vm.cloud_prompt` expose the same prompt for any other terminal. Every
/// entrypoint first installs the bundled skill file at a stable path under
/// `~/.config/cmux/skills/` so the prompt's file reference resolves for any
/// agent, with no network access.
enum CloudAgentSkillLauncher {
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

    /// Installs the skill file and returns the prompt plus the path it names.
    static func promptPayload() throws -> (prompt: String, skillPath: String) {
        let url = try installSkillFile()
        return (kickoffPrompt(skillPath: url.path), url.path)
    }

    /// Installs the skill file and opens a local terminal pane running the
    /// agent with the kickoff prompt, through the same shared path as
    /// `surface.new_terminal` (the pane lands split in the selected
    /// workspace). Returns the created surface payload.
    @discardableResult
    static func openAgent(_ agent: CodingAgent) async throws -> [String: Any] {
        let payload = try promptPayload()
        return try await TerminalController.surfaceNewTerminal(
            machine: .local,
            command: agent.argv(prompt: payload.prompt),
            cwd: nil,
            name: agent.displayName,
            remoteWorkspaceID: nil,
            destination: nil,
            focus: true
        )
    }

    /// Installs the skill file and puts the kickoff prompt on the clipboard.
    @MainActor
    static func copyPrompt() throws {
        let payload = try promptPayload()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload.prompt, forType: .string)
    }
}
