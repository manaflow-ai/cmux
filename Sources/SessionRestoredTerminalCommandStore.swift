import Foundation

enum SessionRestoredTerminalCommandStore {
    private static let directoryName = "cmux-session-terminal-command"

    static func writeLauncherScript(
        command: String,
        workingDirectory: String?,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> URL? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return nil }

        let directoryURL = temporaryDirectory.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

            let scriptURL = directoryURL.appendingPathComponent(
                "\(UUID().uuidString).zsh",
                isDirectory: false
            )
            var lines = [
                "#!/bin/zsh",
                "rm -f -- \"$0\" 2>/dev/null || true"
            ]
            if let workingDirectory = normalized(workingDirectory) {
                let quotedDirectory = shellSingleQuoted(workingDirectory)
                lines.append("{ cd -- \(quotedDirectory) 2>/dev/null || [ ! -d \(quotedDirectory) ]; } || exit $?")
            }
            // Nushell cannot parse the POSIX command (`nu -lc` has no such
            // flags and `nu -c` would be a parse error); run it through
            // /bin/sh with the same run-command-then-exit lifecycle.
            lines.append(#"case "${SHELL:t}" in"#)
            lines.append("  nu) exec /bin/sh -c \(shellSingleQuoted(trimmedCommand)) ;;")
            lines.append("  *) exec \"${SHELL:-/bin/zsh}\" -lc \(shellSingleQuoted(trimmedCommand)) ;;")
            lines.append("esac")

            try (lines.joined(separator: "\n") + "\n").write(
                to: scriptURL,
                atomically: true,
                encoding: .utf8
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return scriptURL
        } catch {
            return nil
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
