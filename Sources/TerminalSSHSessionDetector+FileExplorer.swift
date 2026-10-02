import Foundation

extension TerminalSSHSessionDetector {
    /// Extracts the remote cwd carried by a remote shell's terminal title.
    ///
    /// Plain SSH sessions do not send a trusted local OSC 7 report, but common
    /// shell prompts publish titles such as `user@host:~/project`. The result is
    /// intentionally limited to absolute or home-relative paths so arbitrary
    /// title text can never become a local filesystem path.
    static func remoteWorkingDirectory(fromTitle title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let atIndex = trimmed.firstIndex(of: "@") else { return nil }
        let afterAt = trimmed[trimmed.index(after: atIndex)...]
        guard let colonIndex = afterAt.firstIndex(of: ":") else { return nil }
        var cwd = afterAt[afterAt.index(after: colonIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // A title that includes an explicit SSH port can be rendered as
        // `user@host:22:/path`; accept the path-bearing second separator.
        if let secondColon = cwd.firstIndex(of: ":"),
           cwd[..<secondColon].allSatisfy(\.isNumber) {
            cwd = cwd[cwd.index(after: secondColon)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard cwd == "~" || cwd.hasPrefix("/") || cwd.hasPrefix("~/") else { return nil }
        return cwd
    }
}
