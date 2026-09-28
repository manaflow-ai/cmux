import Foundation

/// A block of code an agent handed the user in a terminal pane, held as the
/// exact text to copy: original newlines, no terminal wrapping, no prompt
/// glyphs, no trailing spaces.
///
/// Blocks come from three places, in decreasing order of trust in the text:
/// an agent offering one explicitly (`cmux code-block`), the agent's own
/// transcript (the markdown it wrote), and fenced text read off the screen.
public struct TerminalCodeBlock: Sendable, Hashable, Identifiable, Codable {
    /// Where the block's text came from.
    public enum Origin: String, Sendable, Hashable, Codable {
        /// Offered by a process in the pane through the socket or CLI.
        case offered
        /// A fenced block in the pane's agent transcript.
        case transcript
        /// A fenced block read from the terminal screen.
        case screen
    }

    /// Content identity: the same language and text always hash to the same
    /// id, so re-detecting a block on every render does not churn the UI.
    public let id: String

    /// A short human label (for example "Deploy the staging build").
    public let label: String?

    /// The fence info string's first word, lowercased (`bash`, `swift`).
    public let language: String?

    /// The text Copy writes and Run pastes.
    public let text: String

    /// Where the text came from.
    public let origin: Origin

    /// Whether the block offers Run. Shell-tagged blocks do by default; an
    /// offer can opt in or out explicitly.
    public let isRunnable: Bool

    /// Creates a block, deriving ``isRunnable`` from the language unless
    /// `runnable` is given.
    public init(
        text: String,
        language: String? = nil,
        label: String? = nil,
        origin: Origin,
        runnable: Bool? = nil
    ) {
        let normalizedLanguage = TerminalCodeBlockLanguage(infoString: language)
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = normalizedLanguage.name
        self.label = (trimmedLabel?.isEmpty ?? true) ? nil : trimmedLabel
        self.text = text
        self.origin = origin
        self.isRunnable = runnable ?? normalizedLanguage.isShell
        self.id = Self.contentID(language: normalizedLanguage.name, text: text)
    }

    /// The number of lines in ``text``.
    public var lineCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// FNV-1a over the language and text; stable across launches, unlike
    /// `Hasher`.
    static func contentID(language: String?, text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (language ?? "").utf8 + [0] + text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

/// Classifies a fence info string.
public struct TerminalCodeBlockLanguage: Sendable, Equatable {
    /// Info-string tags that mean "commands for a POSIX-style shell".
    static let shellTags: Set<String> = [
        "sh", "bash", "zsh", "fish", "ksh", "shell", "console", "terminal",
        "shell-session", "shellsession", "sh-session", "bash-session",
    ]

    /// Tags whose lines mix `$ `-prompted commands with their output.
    static let sessionTags: Set<String> = [
        "console", "terminal", "shell-session", "shellsession", "sh-session", "bash-session",
    ]

    /// The lowercased first word of the info string, or `nil` when empty.
    public let name: String?

    /// Creates a classification from a fence info string such as
    /// `bash title="x"` or `{.zsh}`.
    public init(infoString: String?) {
        let firstWord = (infoString ?? "")
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," })
            .first
            .map(String.init) ?? ""
        let stripped = firstWord
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}."))
            .lowercased()
        name = stripped.isEmpty ? nil : stripped
    }

    /// Whether Run applies to blocks with this tag.
    public var isShell: Bool {
        guard let name else { return false }
        return Self.shellTags.contains(name)
    }

    /// Whether the block is a transcript of a shell session (prompts plus
    /// output) rather than a plain script.
    public var isSession: Bool {
        guard let name else { return false }
        return Self.sessionTags.contains(name)
    }
}
