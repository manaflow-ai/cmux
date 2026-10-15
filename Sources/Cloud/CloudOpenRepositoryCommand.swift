import CmuxFoundation
import Foundation

/// The one `cmux vm clone …` invocation "Open Repository in Cloud…" runs.
///
/// The app does not clone, route, sync secrets, run setup or start the agent itself:
/// it types this command into a new local terminal and the bundled CLI does all of it,
/// so the sheet, the `cmux://cloud/clone` link and a hand-typed `cmux vm clone` share
/// one implementation. The visible terminal is the progress view (the CLI's timed
/// phases stream there) and the TTY the CLI needs to ask before it runs a repository's
/// setup commands. A failure stays on screen with the CLI's own fix.
struct CloudOpenRepositoryCommand: Equatable {
    typealias Agent = CloudAgentSkillLauncher.CodingAgent

    let reference: CloudOpenRepositoryReference
    let agent: Agent?
    /// The first task, already single-line and free of control characters; only with an agent.
    let prompt: String?

    init(reference: CloudOpenRepositoryReference, agent: Agent?, prompt: String?) {
        self.reference = reference
        self.agent = agent
        self.prompt = agent == nil ? nil : Self.sanitizedPrompt(prompt)
    }

    /// The CLI arguments after the executable. Options come before `--`, which the CLI
    /// reads as the start of the prompt.
    var cliArguments: [String] {
        var arguments = ["vm", "clone", reference.cloneArgument]
        if let branch = reference.branch { arguments += ["--branch", branch] }
        if let agent { arguments += ["--agent", agent.rawValue] }
        if let prompt { arguments += ["--", prompt] }
        return arguments
    }

    /// The line typed into the terminal (without the trailing newline).
    func shellLine(executable: String) -> String {
        ([executable] + cliArguments).map(Self.shellWord).joined(separator: " ")
    }

    /// The same command as a person would type it, for the sheet's preview.
    var displayLine: String { shellLine(executable: "cmux") }

    /// The workspace title for the terminal that runs the clone.
    var workspaceTitle: String {
        String(
            format: String(localized: "cloudOpenRepository.workspaceTitle", defaultValue: "Clone %@"),
            reference.displayName
        )
    }

    // MARK: - Text safety

    /// A prompt as one line: newlines and tabs become spaces, every other control
    /// character is dropped (the text is typed into a line editor, where ESC or ^C
    /// would act as keys), runs of spaces collapse, and it is capped. Empty is nil.
    static func sanitizedPrompt(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                scalars.append(" ")
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxPromptLength))
    }

    static let maxPromptLength = 4_000

    /// True when `text` holds a character that must never be typed into a terminal.
    static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// One shell word that every shell a cmux terminal may run (sh, bash, zsh, fish)
    /// reads back unchanged. Bare words stay bare; anything else is single-quoted with
    /// `'` spliced as `'"'"'` and `\` as `'"\\"'`, because fish still interprets `\\`
    /// and `\'` inside single quotes.
    static func shellWord(_ value: String) -> String {
        if value.isPOSIXShellBareWord() { return value }
        // Quotes first: the backslash splice adds quotes of its own.
        let body = value
            .replacingOccurrences(of: "'", with: "'\"'\"'")
            .replacingOccurrences(of: "\\", with: "'\"\\\\\"'")
        return "'" + body + "'"
    }
}
