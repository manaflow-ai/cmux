public import Foundation

/// Builds remote path candidates without consulting the local filesystem or home directory.
public struct RemoteTerminalPathResolver: Sendable {
    /// Creates a remote terminal path resolver.
    public init() {}

    /// Extracts candidate spellings at the clicked column using the terminal's shared token rules.
    /// - Parameters:
    ///   - line: The visible terminal line.
    ///   - column: The zero-based character column under the pointer.
    /// - Returns: Candidate tokens in preferred order.
    public func tokens(in line: String, column: Int) -> [String] {
        line.pathTokenCandidates(containingColumn: column)
    }

    /// Reports whether a token can name a file rather than a web or custom-scheme URL.
    /// - Parameter token: A terminal token or explicit file URL.
    /// - Returns: Whether the token is a path or file URL.
    public func isFileReference(_ token: String) -> Bool {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains("\0"), !token.contains("\n"), !token.contains("\r") else { return false }
        guard let scheme = URL(string: token.unquotedShellToken() ?? token)?.scheme else { return true }
        return scheme.lowercased() == "file"
    }

    /// Reports whether any token resolves against the terminal's working directory.
    ///
    /// Callers use this to skip a live directory query when every token is absolute,
    /// home-relative, or an explicit file URL.
    /// - Parameter tokens: Candidate terminal tokens or file URLs.
    /// - Returns: Whether some spelling is a relative path.
    public func needsWorkingDirectory(tokens: [String]) -> Bool {
        tokens.contains { raw in
            isFileReference(raw) && raw.pathResolutionCandidates().contains {
                if case .relative = reference($0, remoteHost: "") { return true }
                return false
            }
        }
    }

    /// Resolves candidate spellings using only remote directory metadata.
    ///
    /// Candidates retain `..` because collapsing it locally changes the meaning of remote
    /// symlinks. The caller must verify candidates on the remote host, in the returned order.
    /// Named-user tildes are unsupported; `~` always means the authenticated remote user's home.
    /// - Parameters:
    ///   - tokens: Candidate terminal tokens or file URLs.
    ///   - workingDirectory: The source terminal's remote directory, when known.
    ///   - homeDirectory: The home reported by the SSH connection, when known.
    ///   - remoteHost: The configured SSH host, used to validate explicit file URL authorities.
    /// - Returns: Absolute remote paths, with duplicates removed and no local filesystem probes.
    public func candidates(
        tokens: [String],
        workingDirectory: String?,
        homeDirectory: String?,
        remoteHost: String
    ) -> [String] {
        var paths: [String] = []
        for raw in tokens where isFileReference(raw) {
            for spelling in raw.pathResolutionCandidates() {
                let path: String
                switch reference(spelling, remoteHost: remoteHost) {
                case nil:
                    continue
                case .absolute(let absolute):
                    path = absolute
                case .home(let suffix):
                    guard let homeDirectory, homeDirectory.hasPrefix("/") else { continue }
                    path = suffix.map {
                        homeDirectory + (homeDirectory.hasSuffix("/") ? "" : "/") + $0
                    } ?? homeDirectory
                case .relative(let token):
                    guard let workingDirectory, workingDirectory.hasPrefix("/") else { continue }
                    path = workingDirectory + (workingDirectory.hasSuffix("/") ? "" : "/") + token
                }
                guard !path.contains("\0"), !paths.contains(path) else { continue }
                paths.append(path)
            }
        }
        return paths
    }

    private enum Reference {
        case absolute(String)
        /// `~` alone has no suffix; `~/x` has suffix `x`.
        case home(String?)
        case relative(String)
    }

    /// Classifies one spelling; nil for unusable tokens such as named-user tildes or foreign file URLs.
    private func reference(_ spelling: String, remoteHost: String) -> Reference? {
        let token: String
        if let url = URL(string: spelling), let scheme = url.scheme {
            guard scheme.lowercased() == "file", url.user == nil, url.password == nil, url.port == nil,
                  url.host == nil || url.host?.isEmpty == true ||
                    url.host?.lowercased() == "localhost" ||
                    url.host?.lowercased() == remoteHost.lowercased() else { return nil }
            token = url.path
        } else {
            token = spelling
        }
        guard !token.isEmpty else { return nil }
        if token == "~" { return .home(nil) }
        if token.hasPrefix("~/") { return .home(String(token.dropFirst(2))) }
        if token.hasPrefix("~") { return nil }
        if token.hasPrefix("/") { return .absolute(token) }
        return .relative(token)
    }
}
