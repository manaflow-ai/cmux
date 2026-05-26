import Foundation

extension CMUXCLI {
    internal func openSSHLocalCommandValue(shellScript: String?) -> String? {
        guard let shellScript else { return nil }
        let trimmed = shellScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return openSSHCommandOptionValue(posixShellCommand(trimmed))
    }

    internal func openSSHRemoteCommandValue(shellScript: String) -> String {
        openSSHCommandOptionValue(posixShellCommand(shellScript))
    }

    internal func posixShellCommand(_ shellScript: String) -> String {
        "/bin/sh -c " + shellQuote(shellScript)
    }

    internal func openSSHCommandOptionValue(_ command: String) -> String {
        command.replacingOccurrences(of: "%", with: "%%")
    }

    /// Joins self-delimiting POSIX shell snippets with one space; this is not a general shell combiner.
    internal func combinedLocalShellScript(_ parts: [String?]) -> String? {
        let filtered = parts.compactMap { raw -> String? in
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !filtered.isEmpty else { return nil }
        return filtered.joined(separator: " ")
    }
}
