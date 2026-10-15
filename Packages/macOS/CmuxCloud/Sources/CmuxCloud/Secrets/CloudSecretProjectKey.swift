import Foundation

/// The key a project scope is stored under.
///
/// A git remote normalizes to `host/path`, lowercased, without a `.git` suffix, user
/// or port, so `https://github.com/Owner/Repo.git`, `git@github.com:owner/repo` and
/// `ssh://git@github.com:22/owner/repo` all become `github.com/owner/repo`. A directory
/// without a remote uses `local/<name>`.
/// lint:allow namespace-type: the contract's stateless normalizer, shared by the CLI, the app service and the sheet.
public enum CloudSecretProjectKey {
    /// The normalized key for a remote URL, or `nil` for a local path or anything unparseable.
    public static func normalize(remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let host: String
        let path: String
        if let schemeRange = trimmed.range(of: "://") {
            let scheme = trimmed[..<schemeRange.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(scheme),
                  let components = URLComponents(string: trimmed),
                  let parsedHost = components.host else { return nil }
            host = parsedHost
            path = components.path
        } else {
            // scp-like `[user@]host:path`; a path with a slash before the colon is local.
            guard let colon = trimmed.firstIndex(of: ":") else { return nil }
            let authority = trimmed[..<colon]
            guard !authority.contains("/") else { return nil }
            if let at = authority.lastIndex(of: "@") {
                host = String(authority[authority.index(after: at)...])
            } else {
                host = String(authority)
            }
            path = String(trimmed[trimmed.index(after: colon)...])
        }
        var cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleanPath.lowercased().hasSuffix(".git") {
            cleanPath = String(cleanPath.dropLast(".git".count))
        }
        cleanPath = cleanPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty, !cleanPath.isEmpty else { return nil }
        return "\(host)/\(cleanPath)".lowercased()
    }

    /// `local/<name>` for a directory without a usable remote.
    public static func fallback(directoryName: String) -> String {
        "local/\(directoryName)"
    }
}
