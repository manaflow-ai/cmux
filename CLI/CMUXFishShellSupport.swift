import Foundation

extension CMUXCLI {
    func posixShellRemoteCommand(_ command: String) -> String {
        "/bin/sh -c " + shellQuote(command)
    }

    func sshPercentEscapedRemoteCommand(_ remoteCommand: String) -> String {
        remoteCommand.replacingOccurrences(of: "%", with: "%%")
    }

    func combinedLocalShellCommand(_ parts: [String?]) -> String? {
        let filtered = parts.compactMap { raw -> String? in
            guard let raw else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !filtered.isEmpty else { return nil }
        return filtered.joined(separator: " ")
    }

    func combinedLocalCommandForSSH(_ parts: [String?]) -> String? {
        guard let command = combinedLocalShellCommand(parts) else { return nil }
        return "/bin/sh -c \(shellQuote(command))"
    }
}
