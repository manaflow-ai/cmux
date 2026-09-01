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
        let templateParts = splitShellWords(registration.resumeCommand)
        guard !templateParts.isEmpty else { return [] }
        let executable = launchArguments.first
            ?? normalized(registration.defaultExecutable)
            ?? registration.id
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
                resolved.append(contentsOf: part[opening.lowerBound...])
                return resolved
            }
            let key = String(part[opening.upperBound..<closing.lowerBound])
            if let replacement = replacements[key] {
                if replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

    /// Splits a registration template into quote-aware words.
    private func splitShellWords(_ command: String) -> [String] {
        enum Quote {
            case single
            case double
        }

        var words: [String] = []
        var current = ""
        var quote: Quote?
        var escaping = false

        func finishWord() {
            guard !current.isEmpty else { return }
            words.append(current)
            current = ""
        }

        for character in command {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            switch (quote, character) {
            case (.single, "'"), (.double, "\""):
                quote = nil
            case (nil, "'"):
                quote = .single
            case (nil, "\""):
                quote = .double
            case (nil, " "), (nil, "\t"), (nil, "\n"):
                finishWord()
            default:
                current.append(character)
            }
        }
        if escaping {
            current.append("\\")
        }
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
