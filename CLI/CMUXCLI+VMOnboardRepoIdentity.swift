import Foundation

/// Repo-identity helpers for `cmux vm onboard`: naming, transport
/// normalization, same-repo comparison, and the safety gates applied before a
/// URL or checkout name reaches a generated shell `run:` line. Split from
/// `CMUXCLI+VMOnboardDerive.swift` to keep both files within the repo's Swift
/// file length budget.
extension VMOnboardDeriver {
    // MARK: - Repo naming

    static func repoName(fromURL url: String) -> String {
        var last = url.split(separator: "/").last.map(String.init) ?? url
        if let colon = last.lastIndex(of: ":") {
            // scp-style git@host:repo(.git) with no slash after the colon
            last = String(last[last.index(after: colon)...])
        }
        if last.hasSuffix(".git") { last = String(last.dropLast(4)) }
        return last.isEmpty ? "repo" : last
    }

    /// Rewrite scp-style ssh remotes to https so the VM can clone public repos
    /// without the user's SSH identity. Private-repo auth is out of scope for
    /// the prototype; the clone step fails visibly and the spec is editable.
    static func normalizedCloneURL(_ url: String) -> String {
        guard url.hasPrefix("git@"), !url.contains("://"), let colon = url.firstIndex(of: ":") else { return url }
        let host = String(url[url.index(url.startIndex, offsetBy: 4)..<colon])
        var path = String(url[url.index(after: colon)...])
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        return "https://\(host)/\(path)"
    }

    /// Identity key for "is this local checkout the same repo as that URL":
    /// normalize the transport, then strip scheme, credentials, `.git`, and
    /// trailing slashes so `git@github.com:o/r.git` == `https://github.com/o/r/`.
    /// Comparing whole keys (host + owner + repo) prevents scanning a local
    /// checkout that merely shares the basename with the requested repo.
    static func canonicalRepoKey(_ url: String) -> String {
        var key = normalizedCloneURL(url).lowercased()
        if let scheme = key.range(of: "://") { key = String(key[scheme.upperBound...]) }
        if let at = key.firstIndex(of: "@"), !key[..<at].contains("/") {
            key = String(key[key.index(after: at)...])
        }
        while key.hasSuffix("/") { key = String(key.dropLast()) }
        if key.hasSuffix(".git") { key = String(key.dropLast(4)) }
        return key
    }

    /// The spec's clone step runs inside a cloud VM, so only network transports
    /// work; local paths and file:// origins would fail later with a confusing
    /// clone error instead of a clear one at the CLI boundary.
    static func isRemoteCloneURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://")
            || lower.hasPrefix("git://") || lower.hasPrefix("ssh://") {
            return true
        }
        // scp-style git@host:path
        return url.hasPrefix("git@") && url.contains(":")
    }

    /// Clone URLs and repo names are interpolated into generated shell `run:`
    /// lines (clone step, `cd` prefixes) and into the shallow-clone git
    /// invocation, so restrict them to characters that cannot alter shell
    /// parsing. Everything a real git URL needs is in this set.
    static func isShellSafeCloneURL(_ url: String) -> Bool {
        guard !url.isEmpty, !url.hasPrefix("-") else { return false }
        return url.unicodeScalars.allSatisfy { shellSafeURLScalars.contains($0) }
    }

    static func isShellSafeRepoName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy { shellSafeNameScalars.contains($0) }
    }

    private static let shellSafeURLScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@:/._~%+-"
    )
    private static let shellSafeNameScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
    )
}
