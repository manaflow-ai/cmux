import Foundation

/// Builds argv from a registry-owned Vault resume template.
struct VaultResumeRegistrationTemplate: Sendable {
    /// Resolves a registration template into shell-free arguments.
    ///
    /// - Parameters:
    ///   - registration: The normalized registration.
    ///   - sessionID: Provider session identifier.
    ///   - launchArguments: Captured launch argv, including its executable.
    ///   - workingDirectory: Cwd substituted for `{{cwd}}`.
    /// - Returns: Resolved argv, or an empty array when a template is unsafe or incomplete.
    func resumeArguments(
        registration: VaultResumeLaunchRequest.Registration,
        sessionID: String,
        launchArguments: [String],
        workingDirectory: String?
    ) -> [String] {
        guard let templateParts = splitShellWords(registration.resumeCommand),
              !templateParts.isEmpty else {
            return []
        }
        guard let executable = normalized(launchArguments.first)
            ?? normalized(registration.defaultExecutable) else {
            return []
        }
        let sessionDirectory = normalized(registration.sessionDirectory).map {
            ($0 as NSString).expandingTildeInPath
        }
        let replacements: [String: String] = [
            "sessionId": sessionID,
            "sessionPath": sessionID,
            "executable": executable,
            "cwd": normalized(workingDirectory) ?? "",
            "sessionDir": sessionDirectory ?? "",
        ]
        var resolved: [String] = []
        resolved.reserveCapacity(templateParts.count)
        for part in templateParts {
            guard let value = resolveTemplatePart(part, replacements: replacements) else { return [] }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            resolved.append(trimmed)
        }
        return resolved
    }

    /// Resolves placeholders in one shell-word-sized template token.
    private func resolveTemplatePart(
        _ part: String,
        replacements: [String: String]
    ) -> String? {
        var resolved = ""
        var searchStart = part.startIndex
        while let opening = part[searchStart...].range(of: "{{") {
            resolved.append(contentsOf: part[searchStart..<opening.lowerBound])
            guard let closing = part[opening.upperBound...].range(of: "}}") else {
                return nil
            }
            let key = String(part[opening.upperBound..<closing.lowerBound])
            guard let replacement = replacements[key],
                  !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            resolved += replacement
            searchStart = closing.upperBound
        }
        resolved.append(contentsOf: part[searchStart...])
        return resolved
    }

    /// Splits a registration template into quote-aware words.
    private func splitShellWords(_ command: String) -> [String]? {
        enum Quote {
            case single
            case double
        }

        var words: [String] = []
        var current = ""
        var hasToken = false
        var quote: Quote?
        var escaping = false
        let doubleQuoteEscapable: Set<Character> = ["$", "`", "\"", "\\", "\n"]

        func finishWord() {
            guard hasToken else { return }
            words.append(current)
            current = ""
            hasToken = false
        }

        for character in command {
            if escaping {
                hasToken = true
                if quote == .double, !doubleQuoteEscapable.contains(character) {
                    current.append("\\")
                }
                current.append(character)
                escaping = false
                continue
            }
            if quote == nil {
                switch character {
                case ";", "&", "|", "<", ">", "(", ")", "`", "$":
                    // These characters are shell syntax rather than argv data.
                    // Keep such registrations on the explicitly bounded
                    // compatibility path instead of silently changing their
                    // command semantics in a structured restore record.
                    return nil
                case "\n":
                    // An unquoted newline terminates a shell command.
                    return nil
                case "#" where !hasToken:
                    // A comment at a token boundary is not an argv argument.
                    return nil
                default:
                    break
                }
            } else if quote == .double, (character == "$" || character == "`") {
                // Variable and command substitutions are shell behavior, not
                // literal argv data. Preserve their semantics on the bounded
                // compatibility path instead of embedding the unevaluated text.
                return nil
            }
            if character == "\\", quote != .single {
                hasToken = true
                escaping = true
                continue
            }
            switch (quote, character) {
            case (.single, "'"), (.double, "\""):
                quote = nil
            case (nil, "'"):
                hasToken = true
                quote = .single
            case (nil, "\""):
                hasToken = true
                quote = .double
            case (nil, " "), (nil, "\t"), (nil, "\n"):
                finishWord()
            default:
                hasToken = true
                current.append(character)
            }
        }
        guard quote == nil, !escaping else { return nil }
        finishWord()
        return words
    }

    /// Trims a template value and treats blank text as absent.
    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
