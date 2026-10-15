import Foundation

/// User-visible text the package writes into transcripts (a failed turn's
/// message, a brain's error), in the user's language from this package's
/// String Catalog (`Resources/Localizable.xcstrings`).
///
/// Machine-read text is not here: approval option ids ("Allow", "Deny"),
/// approval prompts ("Run `<command>`?") and tool titles ("Read <path>") are
/// stored in their canonical English form because the owner and Home parse
/// them (``ChiefAllowRules/command(inPrompt:)``, Home's tool kinds); Home
/// localizes them when it draws them.
enum ChiefText {
    /// The Chief message a failed turn posts.
    static func turnFailed(_ error: String) -> String {
        String(localized: "chief.turn.failed",
               defaultValue: "Chief could not finish this reply: \(error)\nSend your message again to retry.",
               bundle: .module)
    }

    /// The user's display name when the account has none.
    static var you: String {
        String(localized: "chief.participant.you", defaultValue: "You", bundle: .module)
    }

    /// An agent CLI that is not on `PATH`.
    static func missingExecutable(_ name: String) -> String {
        String(localized: "chief.brain.missingExecutable",
               defaultValue: "Could not find `\(name)` on PATH. Install it or set its path in Chief settings.",
               bundle: .module)
    }

    static var claudeExitedUnexpectedly: String {
        String(localized: "chief.brain.claude.exited", defaultValue: "Claude Code exited unexpectedly.", bundle: .module)
    }

    static func claudeExited(_ detail: String) -> String {
        String(localized: "chief.brain.claude.exitedDetail", defaultValue: "Claude Code exited: \(detail)", bundle: .module)
    }

    static var claudeStoppedBeforeReading: String {
        String(localized: "chief.brain.claude.stoppedBeforeReading",
               defaultValue: "Claude Code stopped before it read the message.", bundle: .module)
    }

    static var codexExitedUnexpectedly: String {
        String(localized: "chief.brain.codex.exited", defaultValue: "Codex exited unexpectedly.", bundle: .module)
    }

    static func codexExited(_ detail: String) -> String {
        String(localized: "chief.brain.codex.exitedDetail", defaultValue: "Codex exited: \(detail)", bundle: .module)
    }

    static var codexNoThread: String {
        String(localized: "chief.brain.codex.noThread", defaultValue: "Codex started a thread without an id.", bundle: .module)
    }

    static var codexNotRunning: String {
        String(localized: "chief.brain.codex.notRunning", defaultValue: "Codex is not running.", bundle: .module)
    }

    /// Codex ended before it answered the request `method` (a JSON-RPC method name).
    static func codexStopped(before method: String) -> String {
        String(localized: "chief.brain.codex.stoppedBefore", defaultValue: "Codex stopped before \(method).", bundle: .module)
    }
}
