public import CmuxNextSettings
public import Foundation

/// A Markdown runbook's Run request (webviews `pages/markdown/runbook.ts`): `cmux.markdown.runBlock
/// {path, command}` types a shell block's command into a new terminal, and `cmux.markdown.runAll
/// {path, prompt}` opens an agent chat that runs the steps, both started in the file's git
/// repository (its folder outside one). The page builds the command and the prompt; the host only
/// checks the click, the file and the text, then opens the terminal or chat. The host reads the
/// page's file once and refuses the run when a followed link showed another file meanwhile.
public nonisolated struct RunbookRun: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// A Run button: the text is a command typed into a new terminal.
        case terminal
        /// Run all: the text is the first prompt of a new agent chat.
        case chat
    }

    /// The longest command a Run button sends, and the longest Run all prompt.
    public static let commandLimit = 64 * 1024
    public static let promptLimit = 128 * 1024

    public let target: Target
    public let text: String

    /// Checks one request. Only the person's click runs anything (a document never runs a command by
    /// itself), only for the page's own file (`isPageFile`), only for a file of this Mac (`local`: the
    /// terminal, the chat and the git root are this Mac's; a Cloud machine's runbook does not run here),
    /// and only non-empty text within its limit.
    public init(target: Target, params: JSONValue, userGesture: Bool, isPageFile: Bool, local: Bool = true) throws {
        guard userGesture else {
            throw PageError(code: "cmux.page.gesture", message: "running a runbook step needs a user gesture")
        }
        guard isPageFile else { throw PageError.invalidParams("path is not this page's file") }
        guard local else { throw PageError(code: "cmux.page.unsupported", message: "a runbook runs only for a file of this Mac") }
        let field = target == .chat ? "prompt" : "command"
        let limit = target == .chat ? Self.promptLimit : Self.commandLimit
        guard let text = params[field]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= limit, !text.contains("\u{0}") else {
            throw PageError.invalidParams("\(field) must be non-empty text")
        }
        self.target = target
        self.text = text
    }

    /// Where the steps of `file` run: its git repository root (`git rev-parse --show-toplevel`, off
    /// the main actor), else its folder.
    @concurrent public func folder(for file: URL, runner: any MarkdownGitRunning = ProcessMarkdownGitRunner()) async -> String {
        let folder = file.deletingLastPathComponent().path
        guard let top = await runner.run(["rev-parse", "--show-toplevel"], in: folder), top.status == 0 else { return folder }
        let root = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.hasPrefix("/") ? root : folder
    }
}
