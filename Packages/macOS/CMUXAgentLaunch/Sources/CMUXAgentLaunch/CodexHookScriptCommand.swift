import Foundation

public extension CodexHookScriptName {
    /// Renders a generated hook script path as one POSIX shell argument.
    ///
    /// Codex stores hook commands as strings and evaluates them with a shell on
    /// Unix. Paths containing shell separators or metacharacters therefore use
    /// a canonical single-quoted representation; paths that are already safe
    /// shell words remain bare for runtimes that execute the command directly.
    /// Codex's command schema has no separate argv field, so this is the narrow
    /// serialization boundary where shell quoting is required.
    ///
    /// - Parameter path: The absolute filesystem path of a generated hook script.
    /// - Returns: A command-string token that evaluates to exactly `path`.
    static func shellCommand(forScriptPath path: String) -> String {
        guard path.range(of: shellSafePathPattern, options: .regularExpression) == nil else {
            return path
        }
        // Close/reopen the single-quoted word around an apostrophe. This form
        // avoids a literal `'''` sequence, which would terminate TOML's
        // multiline literal wrapper around the command.
        return "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Decodes a generated hook path from a command-string token.
    ///
    /// Both the current shell-safe representation and legacy bare paths are
    /// accepted. The caller remains responsible for checking that the returned
    /// path belongs to its expected generated-hook directory and filename set.
    ///
    /// - Parameter command: The command field read from Codex hook configuration.
    /// - Returns: The underlying absolute path, or `nil` for malformed/non-path input.
    static func scriptPath(fromShellCommand command: String) -> String? {
        parseScriptPath(command, allowingLegacyBareShellCharacters: false)
    }

    /// Decodes a generated hook path for ownership and cleanup compatibility.
    ///
    /// Before shell quoting was added, cmux persisted generated paths as bare
    /// command strings. That representation can contain shell characters when a
    /// user's home path does, even though it is still an exact filesystem path
    /// in the stored configuration. Ownership checks may accept that legacy
    /// form because they validate the generated directory and filename after
    /// decoding; launch-argument sanitization should use `scriptPath` instead.
    static func legacyScriptPath(fromShellCommand command: String) -> String? {
        parseScriptPath(command, allowingLegacyBareShellCharacters: true)
    }

    private static func parseScriptPath(
        _ command: String,
        allowingLegacyBareShellCharacters: Bool
    ) -> String? {
        guard !command.isEmpty else { return nil }

        let path: String
        let isCanonicalQuotedPath = command.hasPrefix("'")
        if isCanonicalQuotedPath {
            guard command.hasSuffix("'") else { return nil }
            let encoded = String(command.dropFirst().dropLast())
            let decoded = encoded.replacingOccurrences(of: "'\"'\"'", with: "'")
            // Re-encoding is the parser's structural check: arbitrary shell
            // snippets cannot masquerade as one generated path token.
            guard shellCommand(forScriptPath: decoded) == command else { return nil }
            path = decoded
        } else {
            path = command
        }

        guard path.hasPrefix("/"),
              !path.utf8.contains(0) else {
            return nil
        }
        if !isCanonicalQuotedPath && !allowingLegacyBareShellCharacters {
            guard path.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
            }),
            path.rangeOfCharacter(from: shellMetacharacters) == nil else {
                return nil
            }
        }
        return path
    }
}

private extension CodexHookScriptName {
    static let shellSafePathPattern = "^[A-Za-z0-9_@%+=:,./-]+$"
    static let shellMetacharacters = CharacterSet(
        charactersIn: "'\"`$&;|<>()[\\]{}*?!~#"
    )
}
