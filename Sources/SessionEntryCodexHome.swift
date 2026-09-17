import Foundation

extension SessionEntry {
    /// Returns the Codex state directory owning this transcript, when the
    /// indexed path is under `sessions` or `archived_sessions`.
    ///
    /// Vault can index more than the default `~/.codex` account. Keeping the
    /// owning home beside the structured restore snapshot prevents a later
    /// ambient `CODEX_HOME` from switching the account during resume.
    var codexHomeForResume: String? {
        guard agent == .codex else { return nil }
        if let indexedCodexHome { return indexedCodexHome }
        guard let fileURL else { return nil }
        // Keep the indexing path: the transcript can be symlinked to shared
        // storage while the account's writer locks remain under its own home.
        let path = fileURL.standardizedFileURL.path
        for marker in ["/sessions/", "/archived_sessions/"] {
            guard let range = path.range(of: marker, options: .backwards) else { continue }
            let home = String(path[..<range.lowerBound])
            guard !home.isEmpty, home.hasPrefix("/") else { continue }
            return home
        }
        return nil
    }
}
