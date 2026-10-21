import Foundation

/// How the composer's Send reaches the program (Codex QA F1). The draft goes
/// as one paste (bracketed when the program turned bracketed paste on, as
/// Codex, zsh and vim do), and Return goes as its own keystroke after the
/// paste was written. Sent back to back as typed text plus Enter, Codex's
/// paste-burst detection took the Enter for a newline inside the burst: the
/// prompt stayed a draft until a second, empty Send. Portable, unit tested.
public struct ComposerSubmit: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// The whole draft, one paste (several lines stay one paste).
        case paste(String)
        /// Return, as a separate write once the paste is out.
        case enter
    }

    /// Time between the paste and its Return: the paste leaves in its own
    /// write and a program reading in bursts sees Return after it, not in it.
    public static let enterDelay: Duration = .milliseconds(60)

    public let steps: [Step]

    public init(text: String, pressReturn: Bool) {
        var steps: [Step] = []
        if !text.isEmpty { steps.append(.paste(text)) }
        if pressReturn { steps.append(.enter) }
        self.steps = steps
    }

    /// Send with attachments (Codex QA F1 re-check): the uploaded files' Mac
    /// paths, shell-quoted, then the draft's text, as one paste; Return
    /// follows when the draft had text (the prompt is meant to run, as for a
    /// text-only Send). Paths alone are inserted for the person to finish.
    public init(attachmentPaths paths: [String], text: String, pressReturn: Bool = true) {
        let quoted = paths.map(Self.shellQuoted).joined(separator: " ")
        let line = text.isEmpty ? quoted + " " : quoted + " " + text
        self.init(text: line, pressReturn: pressReturn && !text.isEmpty)
    }

    /// A path as one shell word: bare when it has only safe characters, else single-quoted.
    public static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,:@%")
        if !path.isEmpty, path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether Return waits for `enterDelay` (it follows a paste).
    public var delaysEnter: Bool {
        steps.first.map { if case .paste = $0 { true } else { false } } ?? false
    }
}
