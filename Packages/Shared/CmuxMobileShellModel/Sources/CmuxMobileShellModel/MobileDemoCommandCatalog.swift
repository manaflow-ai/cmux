public import Foundation

/// THE single place demonstration shell commands are defined.
///
/// Every demo terminal shares this table. `MobileDemoTerminalEngine` owns the
/// line discipline and the per-session filesystem commands (`cd`, `ls`,
/// `pwd`, `cat`, `clear`); everything else the reviewer can type resolves
/// here. To showcase a new command for App Review, add one entry to
/// ``responders`` — no engine or per-terminal changes needed. Keep outputs
/// realistic English developer content with no internal build-lane
/// vocabulary, and end every line with `\r\n`.
public enum MobileDemoCommandCatalog {
    /// What a responder knows about the invocation.
    public struct Context: Sendable {
        /// Everything after the command name, whitespace-trimmed ("" if none).
        public let arguments: String
        /// The session's absolute working directory (tracks `cd`).
        public let workingDirectory: String
        /// The engine's injected clock, so time output is testable.
        public let now: Date

        /// Creates a responder context.
        public init(arguments: String, workingDirectory: String, now: Date) {
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.now = now
        }
    }

    /// A canned command implementation: context in, VT output out.
    public typealias Responder = @Sendable (Context) -> String

    /// The showcase command table. Add reviewer-facing commands here.
    public static let responders: [String: Responder] = [
        "echo": { context in
            context.arguments + "\r\n"
        },
        "whoami": { _ in
            "demo\r\n"
        },
        "hostname": { _ in
            "demo-mac.local\r\n"
        },
        "uname": { _ in
            "Darwin\r\n"
        },
        "date": { context in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            return formatter.string(from: context.now) + "\r\n"
        },
        "git": { context in
            gitResponse(argument: context.arguments)
        },
        "help": { _ in
            "Available commands: ls, cd, pwd, cat, echo, git, date, whoami, clear\r\n"
        },
    ]

    /// Resolves one showcase command, or `nil` for command-not-found.
    static func response(command: String, context: Context) -> String? {
        responders[command]?(context)
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
