public import Foundation

/// One demonstration terminal's canned starting state.
///
/// `transcript` is raw VT/ANSI text shown as the terminal's existing history;
/// `prompt` is what the simulated shell prints before reading a command; the
/// working directory and file table feed the canned command responses.
public struct MobileDemoTerminalScript: Equatable, Sendable {
    /// The terminal surface identifier this script backs.
    public let surfaceID: String
    /// Canned VT/ANSI history rendered above the first prompt.
    public let transcript: String
    /// The simulated shell prompt (may contain ANSI color sequences).
    public let prompt: String
    /// The simulated current working directory (`pwd`).
    public let workingDirectory: String
    /// File names listed by `ls`, with optional `cat` contents.
    public let files: [MobileDemoTerminalFile]

    /// Creates a demo terminal script.
    public init(
        surfaceID: String,
        transcript: String,
        prompt: String,
        workingDirectory: String,
        files: [MobileDemoTerminalFile] = []
    ) {
        self.surfaceID = surfaceID
        self.transcript = transcript
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.files = files
    }
}

/// One canned file visible to the demo shell's `ls` and `cat`.
public struct MobileDemoTerminalFile: Equatable, Sendable {
    /// The file name shown by `ls`.
    public let name: String
    /// Whether `ls` colors the entry as a directory.
    public let isDirectory: Bool
    /// Plain-text `cat` contents, or `nil` for directories/binaries.
    public let contents: String?

    /// Creates a canned file entry.
    public init(name: String, isDirectory: Bool = false, contents: String? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.contents = contents
    }
}

/// A local, deterministic PTY simulacrum for demonstration terminals.
///
/// The engine renders canned session history and then behaves like a minimal
/// line-disciplined shell: typed characters echo immediately, backspace erases,
/// Ctrl-C aborts the line, and Enter runs a small canned command table (`ls`,
/// `pwd`, `git status`, `echo`, `cat`, …) so App Review sees a terminal that
/// responds to input exactly where a live Mac session would. All output is
/// plain VT bytes delivered through the same output stream the real terminal
/// pipeline uses; nothing here talks to a network.
@MainActor
public final class MobileDemoTerminalEngine {
    /// Bounds retained per-terminal history so an adversarial typing session
    /// cannot grow memory without limit. Old history simply scrolls away.
    static let maximumTranscriptUTF8Bytes = 256 * 1_024

    private struct SessionState {
        var script: MobileDemoTerminalScript
        /// Everything already "on screen" before the current prompt+line.
        var transcript: String
        /// The current, not-yet-executed input line.
        var lineBuffer: String
    }

    private var sessionsBySurfaceID: [String: SessionState] = [:]
    private let now: @Sendable () -> Date

    /// Creates an engine over the given terminal scripts.
    /// - Parameters:
    ///   - scripts: One script per demo terminal surface.
    ///   - now: Clock used by the `date` command; injected for deterministic tests.
    public init(
        scripts: [MobileDemoTerminalScript],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        for script in scripts {
            sessionsBySurfaceID[script.surfaceID] = SessionState(
                script: script,
                transcript: script.transcript,
                lineBuffer: ""
            )
        }
    }

    /// Whether this engine owns the given terminal surface.
    public func ownsSurface(_ surfaceID: String) -> Bool {
        sessionsBySurfaceID[surfaceID] != nil
    }

    /// The full-screen replay for a (re)mounted surface: canned history plus
    /// the prompt and any un-executed typed input, so a remount restores
    /// exactly what the user last saw.
    public func replayBytes(surfaceID: String) -> Data? {
        guard let session = sessionsBySurfaceID[surfaceID] else { return nil }
        let screen = session.transcript + session.script.prompt + session.lineBuffer
        return Data(screen.utf8)
    }

    /// Feeds typed input into the simulated shell and returns the bytes to
    /// echo back to the terminal view (echoed characters, erase sequences,
    /// command output, fresh prompts). Returns `nil` for surfaces this engine
    /// does not own.
    public func inputBytes(_ text: String, surfaceID: String) -> Data? {
        guard var session = sessionsBySurfaceID[surfaceID] else { return nil }
        var output = ""
        var scalars = Substring(text).unicodeScalars[...]

        while let scalar = scalars.first {
            scalars = scalars.dropFirst()
            switch scalar {
            case "\r", "\n":
                // Swallow the LF of a CRLF pair so one Enter runs one command.
                if scalar == "\r", scalars.first == "\n" {
                    scalars = scalars.dropFirst()
                }
                output += executeLine(&session)
            case "\u{7F}", "\u{08}":
                if !session.lineBuffer.isEmpty {
                    session.lineBuffer.removeLast()
                    output += "\u{08} \u{08}"
                }
            case "\u{03}":
                // Ctrl-C: abort the line like a shell.
                session.lineBuffer = ""
                output += "^C\r\n" + session.script.prompt
                appendToTranscript(&session, "^C\r\n")
            case "\u{0C}":
                // Ctrl-L: clear the screen, keep the typed line.
                session.transcript = ""
                output += "\u{1B}[2J\u{1B}[H" + session.script.prompt + session.lineBuffer
            case "\u{1B}":
                // Swallow escape sequences (arrow keys, etc.) instead of
                // echoing raw control bytes into the canned session.
                skipEscapeSequence(&scalars)
            default:
                if scalar.properties.generalCategory == .control {
                    continue
                }
                session.lineBuffer.unicodeScalars.append(scalar)
                output.unicodeScalars.append(scalar)
            }
        }

        sessionsBySurfaceID[surfaceID] = session
        guard !output.isEmpty else { return Data() }
        return Data(output.utf8)
    }

    /// Runs the buffered line through the canned command table. Returns the
    /// bytes to echo (newline, command output, next prompt) and folds the
    /// exchange into the transcript so replay stays consistent.
    private func executeLine(_ session: inout SessionState) -> String {
        let line = session.lineBuffer
        session.lineBuffer = ""
        let response = MobileDemoCommandResponder.respond(
            to: line,
            script: session.script,
            now: now()
        )
        switch response {
        case .output(let body):
            let echoed = "\r\n" + body
            appendToTranscript(&session, line + echoed)
            return echoed + session.script.prompt
        case .clearScreen:
            session.transcript = ""
            return "\u{1B}[2J\u{1B}[H" + session.script.prompt
        }
    }

    private func appendToTranscript(_ session: inout SessionState, _ text: String) {
        session.transcript += text
        // Trim from the front on overflow; the terminal only replays what a
        // real scrollback would still retain.
        while session.transcript.utf8.count > Self.maximumTranscriptUTF8Bytes {
            session.transcript.removeFirst(
                session.transcript.count - session.transcript.count * 3 / 4
            )
        }
    }

    /// Consumes one ESC-initiated sequence (CSI/SS3/two-byte) from the input.
    private func skipEscapeSequence(_ scalars: inout Substring.UnicodeScalarView.SubSequence) {
        guard let introducer = scalars.first else { return }
        scalars = scalars.dropFirst()
        switch introducer {
        case "[":
            // CSI: parameter bytes 0x30–0x3F, intermediates 0x20–0x2F, final 0x40–0x7E.
            while let byte = scalars.first {
                scalars = scalars.dropFirst()
                if (0x40...0x7E).contains(byte.value) { break }
            }
        case "O":
            // SS3: exactly one final byte.
            if scalars.first != nil { scalars = scalars.dropFirst() }
        default:
            break
        }
    }
}

/// The canned command table behind the demonstration shell.
enum MobileDemoCommandResponder {
    enum Response: Equatable {
        /// Print this VT text (already `\r\n`-terminated unless empty).
        case output(String)
        /// Clear the screen and print a fresh prompt.
        case clearScreen
    }

    static func respond(
        to line: String,
        script: MobileDemoTerminalScript,
        now: Date
    ) -> Response {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .output("") }
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        let command = String(parts.first ?? "")
        let argument = parts.count > 1 ? String(parts[1]) : ""

        switch command {
        case "ls":
            let entries = script.files.map { file in
                file.isDirectory ? "\u{1B}[1;34m\(file.name)\u{1B}[0m" : file.name
            }
            guard !entries.isEmpty else { return .output("") }
            return .output(entries.joined(separator: "  ") + "\r\n")
        case "pwd":
            return .output(script.workingDirectory + "\r\n")
        case "whoami":
            return .output("demo\r\n")
        case "date":
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            return .output(formatter.string(from: now) + "\r\n")
        case "echo":
            return .output(argument + "\r\n")
        case "clear":
            return .clearScreen
        case "cat":
            guard !argument.isEmpty else { return .output("") }
            if let file = script.files.first(where: { $0.name == argument }),
               let contents = file.contents {
                let normalized = contents
                    .replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\n", with: "\r\n")
                return .output(normalized.hasSuffix("\r\n") ? normalized : normalized + "\r\n")
            }
            return .output("cat: \(argument): No such file or directory\r\n")
        case "git":
            return .output(gitResponse(argument: argument))
        case "uname":
            return .output("Darwin\r\n")
        case "hostname":
            return .output("demo-mac.local\r\n")
        default:
            return .output("zsh: command not found: \(command)\r\n")
        }
    }

    private static func gitResponse(argument: String) -> String {
        let subcommand = argument.split(separator: " ").first.map(String.init) ?? ""
        switch subcommand {
        case "status":
            return "On branch main\r\n" +
                "Your branch is up to date with 'origin/main'.\r\n" +
                "\r\nnothing to commit, working tree clean\r\n"
        case "log":
            return "\u{1B}[33mcommit 4c1f2ab\u{1B}[0m (HEAD -> main, origin/main)\r\n" +
                "    webhook: retry delivery with exponential backoff\r\n" +
                "\u{1B}[33mcommit 91d03fe\u{1B}[0m\r\n" +
                "    tests: cover session-restore race\r\n" +
                "\u{1B}[33mcommit b7a2c10\u{1B}[0m\r\n" +
                "    ci: cache package resolution between runs\r\n"
        case "branch":
            return "* \u{1B}[32mmain\u{1B}[0m\r\n"
        case "diff":
            return "\r\n"
        default:
            return "git: '\(subcommand)' is not a git command. See 'git --help'.\r\n"
        }
    }
}
