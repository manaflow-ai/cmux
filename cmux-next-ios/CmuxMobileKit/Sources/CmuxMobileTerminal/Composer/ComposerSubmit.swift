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
        /// The draft as typed keys (a one-line draft for a full-screen app).
        case type(String)
        /// Return, as a separate write once the paste is out.
        case enter
    }

    /// Time between the paste and its Return: the paste leaves in its own
    /// write and a program reading in bursts sees Return after it, not in it.
    public static let enterDelay: Duration = .milliseconds(60)
    /// Time between typed text and its Return: past the window in which an
    /// agent's paste-burst detection (Codex: about 120 ms after a burst of
    /// unbracketed characters) takes Return for a newline (Codex QA F1),
    /// should one run on the alternate screen.
    public static let typedEnterDelay: Duration = .milliseconds(250)

    /// The wait before Return: after a paste, after typed text, or none.
    public var enterWait: Duration? {
        switch steps.first {
        case .paste: Self.enterDelay
        case .type: Self.typedEnterDelay
        case .enter, nil: nil
        }
    }

    public let steps: [Step]

    /// `fullScreenApp`: the program is on the alternate screen (vim, less,
    /// htop). A one-line draft is typed there: vim takes a bracketed paste
    /// as text even in normal mode, so `:q` was inserted, not run.
    public init(text: String, pressReturn: Bool, fullScreenApp: Bool = false) {
        var steps: [Step] = []
        if !text.isEmpty {
            steps.append(fullScreenApp && !text.contains(where: \.isNewline) ? .type(text) : .paste(text))
        }
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

    /// Whether Return waits (it follows a paste or typed text: `enterWait`).
    public var delaysEnter: Bool { enterWait != nil }
}
