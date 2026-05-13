import Foundation

extension CMUXCLI {
    internal func openSSHLocalCommandValue(shellScript: String?) -> String? {
        guard let shellScript else { return nil }
        let trimmed = shellScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return openSSHCommandOptionValue(posixShellCommand(trimmed))
    }

    internal func openSSHRemoteCommandValue(shellScript: String) -> String {
        openSSHCommandOptionValue(remoteLoginShellSafePOSIXCommand(shellScript))
    }

    internal func posixShellCommand(_ shellScript: String) -> String {
        "/bin/sh -c " + shellQuote(shellScript)
    }

    internal func remoteLoginShellSafePOSIXCommand(_ shellScript: String) -> String {
        let encodedScript = Data(shellScript.utf8).base64EncodedString()
        let wrapper = [
            "cmux_b64=\(encodedScript)",
            "cmux_tmp=$(mktemp \"${TMPDIR:-/tmp}/cmux-remote-command.XXXXXX\") || exit 1",
            "cmux_cleanup() { rm -f -- \"$cmux_tmp\" 2>/dev/null || true; }",
            "trap \"cmux_cleanup\" EXIT HUP INT TERM",
            "(printf %s \"$cmux_b64\" | base64 -d 2>/dev/null || printf %s \"$cmux_b64\" | base64 -D 2>/dev/null) > \"$cmux_tmp\" || exit 1",
            "chmod 700 \"$cmux_tmp\" >/dev/null 2>&1 || true",
            "/bin/sh \"$cmux_tmp\"",
            "cmux_status=$?",
            "trap - EXIT HUP INT TERM",
            "cmux_cleanup",
            "exit $cmux_status",
        ].joined(separator: "; ")
        return posixShellCommand(wrapper)
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
