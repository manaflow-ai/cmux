import Foundation

/// Read-only lookup of Claude's per-folder trust flag in an account's `.claude.json`.
public enum ClaudeConfigTrustReader {
    /// Whether `projects[<cwd or any ancestor>].hasTrustDialogAccepted` is true for `account`.
    /// Missing, unreadable or corrupt files count as untrusted. Symlinks are not resolved
    /// because Claude keys projects by the literal working directory.
    public static func isTrusted(
        workingDirectory: String,
        account: ClaudeAccount,
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> Bool {
        let base = account.configDirectory ?? (homeDirectory as NSString).standardizingPath
        let path = (base as NSString).appendingPathComponent(".claude.json")
        guard let data = fileManager.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String: Any]
        else { return false }

        var current = (workingDirectory as NSString).standardizingPath
        while true {
            if let entry = projects[current] as? [String: Any],
               (entry["hasTrustDialogAccepted"] as? Bool) == true {
                return true
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
    }
}
