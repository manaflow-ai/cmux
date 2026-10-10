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
        guard let colonIndex = afterAt.indices.first(where: { index in
            guard afterAt[index] == ":" else { return false }
            let next = afterAt.index(after: index)
            guard next < afterAt.endIndex else { return false }
            return afterAt[next] == "/" || afterAt[next] == "~"
        }) else { return nil }
        let cwd = afterAt[afterAt.index(after: colonIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cwd == "~" || cwd.hasPrefix("/") || cwd.hasPrefix("~/") else { return nil }
        return cwd
    }
}
