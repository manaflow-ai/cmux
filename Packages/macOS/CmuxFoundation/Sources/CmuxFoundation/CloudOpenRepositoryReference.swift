import Foundation

/// A repository a Cloud machine can clone, parsed from what a person typed or pasted:
/// `owner/repo`, `https://github.com/owner/repo[/tree/<branch>]`, `git@host:path.git`,
/// `ssh://…`, or any https git URL.
///
/// These are the rules `cmux vm clone <repo>` applies (`CMUXCLI.parseVMCloneRepoSpec`),
/// kept in this package so the app's "Open Repository in Cloud…" sheet validates a field
/// exactly the way the CLI it runs will, without spawning it. The CLI target links this
/// package, so it can adopt this type and delete its copy; until then
/// `CloudOpenRepositoryCLIParityTests` runs the CLI's `--dry-run --json` over a shared
/// corpus and fails when the two disagree.
///
/// `.` (a local checkout's origin) needs local git state and is not accepted here.
public struct CloudOpenRepositoryReference: Equatable, Sendable {
    /// The URL handed to `git clone`. GitHub repositories always clone over https, so the
    /// machine's GH_TOKEN credential helper applies.
    public let cloneURL: String
    /// The repository's own name (the last path component without `.git`).
    public let name: String
    /// The owner or group path, when the URL has one.
    public let owner: String?
    /// The branch named by `/tree/<branch>` or the override; nil is the default branch.
    public let branch: String?
    /// Lowercased `host/path` without `.git` (`github.com/owner/repo`), the Cloud
    /// Secrets project key.
    public let projectKey: String

    /// `owner/repo`, or the bare name.
    public var displayName: String { owner.map { "\($0)/\(name)" } ?? name }

    /// True for github.com, the only host the machine's GH_TOKEN helper answers for.
    public var isGitHub: Bool { projectKey.hasPrefix("github.com/") }

    /// The `<repo>` argument for `cmux vm clone` that names exactly this repository:
    /// `owner/repo` on GitHub (the branch travels as `--branch`), else the clone URL.
    public var cloneArgument: String {
        if isGitHub, let owner { return "\(owner)/\(name)" }
        return cloneURL
    }

    public init(cloneURL: String, name: String, owner: String?, branch: String?, projectKey: String) {
        self.cloneURL = cloneURL
        self.name = name
        self.owner = owner
        self.branch = branch
        self.projectKey = projectKey
    }
}

/// Why a repository field was refused. No case carries the raw text, so a credential
/// pasted into the field never travels in an error.
public enum CloudOpenRepositoryReferenceError: Error, Equatable, Sendable {
    case empty
    /// Not one of the accepted forms (`.` included).
    case unrecognized
    /// A password, or a user name on http(s), is in the URL.
    case credentialsInURL
    /// The branch (from `/tree/…` or the override) is not a usable git branch name.
    case invalidBranch
}

extension CloudOpenRepositoryReference {
    /// Parses a repository field with `cmux vm clone`'s rules. `branchOverride` (the
    /// CLI's `--branch`) wins over a branch in the URL.
    public static func parse(
        _ raw: String,
        branchOverride: String? = nil
    ) -> Result<CloudOpenRepositoryReference, CloudOpenRepositoryReferenceError> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(.empty) }
        if let override = branchOverride, !isValidBranch(override) { return .failure(.invalidBranch) }

        var host: String
        let segments: [String]
        var urlForGeneric: String
        if let schemeRange = text.range(of: "://") {
            let scheme = text[..<schemeRange.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git"].contains(scheme),
                  let components = URLComponents(string: text),
                  let rawHost = components.host, !rawHost.isEmpty else {
                return .failure(.unrecognized)
            }
            if components.password != nil { return .failure(.credentialsInURL) }
            if components.user != nil, scheme == "https" || scheme == "http" { return .failure(.credentialsInURL) }
            guard components.query == nil, components.fragment == nil else { return .failure(.unrecognized) }
            host = rawHost.lowercased()
            segments = components.path.split(separator: "/").map(String.init)
            urlForGeneric = text
            while urlForGeneric.hasSuffix("/") { urlForGeneric.removeLast() }
        } else if let scp = scpLike(text) {
            host = scp.host
            segments = scp.path.split(separator: "/").map(String.init)
            urlForGeneric = text
        } else if isShorthand(text) {
            host = "github.com"
            segments = text.split(separator: "/").map(String.init)
            urlForGeneric = ""
        } else {
            return .failure(.unrecognized)
        }
        if host == "www.github.com" { host = "github.com" }

        if host == "github.com" {
            guard segments.count >= 2 else { return .failure(.unrecognized) }
            let owner = segments[0]
            let name = stripGitSuffix(segments[1])
            guard isValidPathComponent(owner), isValidPathComponent(name) else { return .failure(.unrecognized) }
            var urlBranch: String?
            if segments.count >= 4, segments[2] == "tree" {
                let joined = segments[3...].joined(separator: "/")
                urlBranch = joined.removingPercentEncoding ?? joined
            }
            let branch = branchOverride ?? urlBranch
            if let branch, !isValidBranch(branch) { return .failure(.invalidBranch) }
            return .success(CloudOpenRepositoryReference(
                cloneURL: "https://github.com/\(owner)/\(name).git",
                name: name,
                owner: owner,
                branch: branch,
                projectKey: "github.com/\(owner)/\(name)".lowercased()
            ))
        }

        // Any other host: clone the URL exactly as given.
        guard let last = segments.last else { return .failure(.unrecognized) }
        let name = stripGitSuffix(last)
        guard isValidPathComponent(name) else { return .failure(.unrecognized) }
        var keySegments = segments
        keySegments[keySegments.count - 1] = name
        guard keySegments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return .failure(.unrecognized) }
        let owner = segments.count > 1 ? segments.dropLast().joined(separator: "/") : nil
        return .success(CloudOpenRepositoryReference(
            cloneURL: urlForGeneric,
            name: name,
            owner: owner,
            branch: branchOverride,
            projectKey: ([host] + keySegments).joined(separator: "/").lowercased()
        ))
    }

    /// The GitHub repository a pasted text names, for prefilling a field: an
    /// `https://github.com/…` URL (optionally with `/tree/<branch>`, `/pull/…` or
    /// `/blob/…` after the repository) or `git@github.com:owner/repo.git`. A bare
    /// `owner/repo` on the clipboard is too ambiguous to count. Returns the text to put
    /// in the field, trimmed to the repository (and branch), or nil.
    public static func gitHubFieldText(fromPasteboardText raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2_048, !text.contains(where: { $0.isNewline || $0 == " " }) else { return nil }
        let lowered = text.lowercased()
        if lowered.hasPrefix("git@github.com:") {
            guard case .success(let reference) = parse(text), reference.isGitHub else { return nil }
            return text
        }
        guard lowered.hasPrefix("https://github.com/") || lowered.hasPrefix("https://www.github.com/")
                || lowered.hasPrefix("http://github.com/") || lowered.hasPrefix("github.com/"),
              var components = URLComponents(string: lowered.hasPrefix("github.com/") ? "https://" + text : text) else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        let segments = components.path.split(separator: "/").map(String.init)
        guard segments.count >= 2, !gitHubSitePaths.contains(segments[0].lowercased()) else { return nil }
        var kept = Array(segments.prefix(2))
        // Keep a branch link; drop issue, PR, blob and other subpages.
        if segments.count >= 4, segments[2] == "tree" { kept = segments }
        components.scheme = "https"
        components.path = "/" + kept.joined(separator: "/")
        guard let candidate = components.string,
              case .success(let reference) = parse(candidate), reference.isGitHub else { return nil }
        return candidate
    }

    /// First path segments of github.com pages that are not an owner.
    static let gitHubSitePaths: Set<String> = [
        "apps", "explore", "features", "login", "marketplace", "new", "notifications",
        "orgs", "pulls", "issues", "search", "settings", "sponsors", "topics",
    ]

    // MARK: - Rules (mirror CMUXCLI+VMClone.swift)

    /// `[user@]host:path` (git's scp-like syntax). Requires a dotted host or a user so a
    /// bare `name:thing` is not mistaken for a remote.
    static func scpLike(_ text: String) -> (host: String, path: String)? {
        guard !text.contains("://"), let colon = text.firstIndex(of: ":") else { return nil }
        let authority = String(text[..<colon])
        var path = String(text[text.index(after: colon)...])
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty, !authority.isEmpty, !authority.contains("/") else { return nil }
        var hostPart = authority
        var hasUser = false
        if let at = authority.lastIndex(of: "@") {
            let user = authority[..<at]
            hostPart = String(authority[authority.index(after: at)...])
            guard !user.isEmpty, !user.contains(":") else { return nil }
            hasUser = true
        }
        let hostAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !hostPart.isEmpty,
              hostPart.unicodeScalars.allSatisfy({ hostAllowed.contains($0) }),
              hasUser || hostPart.contains(".") else { return nil }
        return (hostPart.lowercased(), path)
    }

    /// `owner/repo` (optionally `.git`): exactly two GitHub-safe components.
    static func isShorthand(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return false }
        return isValidPathComponent(parts[0]) && isValidPathComponent(stripGitSuffix(parts[1]))
    }

    static func stripGitSuffix(_ value: String) -> String {
        value.lowercased().hasSuffix(".git") ? String(value.dropLast(4)) : value
    }

    /// Letters, digits, `.`, `_`, `-`; not starting with `.` or `-`.
    static func isValidPathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200, !value.hasPrefix("."), !value.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A conservative subset of `git check-ref-format --branch`.
    public static func isValidBranch(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255,
              !value.hasPrefix("-"), !value.hasPrefix("/"), !value.hasSuffix("/"),
              !value.hasSuffix("."), !value.hasSuffix(".lock"),
              !value.contains(".."), !value.contains("//"), !value.contains("@{"),
              value != "@" else { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\")
            .union(.whitespacesAndNewlines)
            .union(.controlCharacters)
        return !value.unicodeScalars.contains { forbidden.contains($0) }
    }
}
