import Foundation

/// Expands a cmux agent launch template into shell-free arguments.
///
/// Templates are intentionally limited to shell words and the five cmux
/// substitutions (`executable`, `sessionId`, `sessionPath`, `cwd`, and
/// `sessionDir`). No shell is executed while rendering, so the result can be
/// passed directly to `execve` or another typed process API.
public struct AgentLaunchTemplateRenderer: Sendable, Equatable {
    /// Creates a stateless template renderer.
    public init() {}

    /// Renders one template, or returns `nil` when it is malformed or a
    /// required substitution is empty.
    public func arguments(
        template: String,
        executable: String,
        sessionID: String,
        workingDirectory: String?,
        sessionDirectory: String?
    ) -> [String]? {
        guard let templateParts = splitShellWords(template),
              !templateParts.isEmpty else {
            return nil
        }
        let replacements: [String: String] = [
            "sessionId": sessionID,
            "sessionPath": sessionID,
            "executable": executable,
            "cwd": normalized(workingDirectory) ?? "",
            "sessionDir": normalized(sessionDirectory) ?? "",
        ]
        var resolved: [String] = []
        for part in templateParts {
            guard let value = resolveTemplatePart(part, replacements: replacements) else {
                return nil
            }
            resolved.append(value)
        }
        return resolved
    }

    private func resolveTemplatePart(
        _ part: String,
        replacements: [String: String]
    ) -> String? {
        var resolved = ""
        var searchStart = part.startIndex
        while let opening = part[searchStart...].range(of: "{{") {
            resolved.append(contentsOf: part[searchStart..<opening.lowerBound])
            guard let closing = part[opening.upperBound...].range(of: "}}") else {
                resolved.append(contentsOf: part[opening.lowerBound...])
                return resolved
            }
            let key = String(part[opening.upperBound..<closing.lowerBound])
            if let replacement = replacements[key] {
                guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                resolved += replacement
            } else {
                resolved.append(contentsOf: part[opening.lowerBound..<closing.upperBound])
            }
            searchStart = closing.upperBound
        }
        resolved.append(contentsOf: part[searchStart...])
        return resolved
    }

    private func splitShellWords(_ command: String) -> [String]? {
        enum Quote: Equatable { case single, double }
        var words: [String] = []
        var current = ""
        var quote: Quote?
        var escaping = false
        var wordStarted = false

        func finishWord() {
            guard wordStarted else { return }
            words.append(current)
            current = ""
            wordStarted = false
        }

        for character in command {
            if escaping {
                if quote == .double,
                   !Self.isDoubleQuoteEscapable(character) {
                    current.append("\\")
                }
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                if quote == .single {
                    // Backslashes are literal inside POSIX single quotes.
                    current.append(character)
                    wordStarted = true
                } else {
                    escaping = true
                    wordStarted = true
                }
                continue
            }
            switch (quote, character) {
            case (.single, "'"), (.double, "\""):
                quote = nil
                wordStarted = true
            case (nil, "'"):
                quote = .single
                wordStarted = true
            case (nil, "\""):
                quote = .double
                wordStarted = true
            case (nil, " "), (nil, "\t"), (nil, "\n"):
                finishWord()
            default:
                current.append(character)
                wordStarted = true
            }
        }
        guard !escaping, quote == nil else { return nil }
        finishWord()
        return words
    }

    private static func isDoubleQuoteEscapable(_ character: Character) -> Bool {
        character == "$"
            || character == "`"
            || character == "\""
            || character == "\\"
            || character == "\n"
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
