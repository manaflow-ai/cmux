import Foundation

extension GitMetadataService {
    /// Selects the preferred browsable repository remote from `git remote -v`
    /// fetch output.
    nonisolated static func repositoryLink(fromGitRemoteVOutput output: String) -> GitRepositoryLink? {
        var linkByRemoteName: [String: GitRepositoryLink] = [:]

        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3,
                  parts[2] == "(fetch)" else {
                continue
            }

            let remoteName = String(parts[0])
            guard linkByRemoteName[remoteName] == nil,
                  let link = repositoryLink(
                remoteName: remoteName,
                remoteURL: String(parts[1])
            ) else {
                continue
            }
            // Git fetches from the first URL after any empty reset; later
            // multivar URLs are additional push destinations.
            linkByRemoteName[remoteName] = link
        }

        return linkByRemoteName.values.min { lhs, rhs in
            let lhsPriority = repositoryLinkRemotePriority(lhs.remoteName)
            let rhsPriority = repositoryLinkRemotePriority(rhs.remoteName)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }

            let lhsFolded = lhs.remoteName.lowercased()
            let rhsFolded = rhs.remoteName.lowercased()
            if lhsFolded != rhsFolded {
                return lhsFolded < rhsFolded
            }
            return lhs.remoteName < rhs.remoteName
        }
    }

    /// Produces one sanitized browser URL from a remote name and its Git URL.
    private nonisolated static func repositoryLink(remoteName: String, remoteURL: String) -> GitRepositoryLink? {
        guard remoteName.utf8.count <= 256,
              let normalizedURL = normalizedBrowsableRepositoryURL(from: remoteURL),
              let displayName = repositoryLinkDisplayName(from: normalizedURL.path) else {
            return nil
        }
        return GitRepositoryLink(remoteName: remoteName, displayName: displayName, url: normalizedURL)
    }

    /// Gives `origin`, then `upstream`, priority over named fallback remotes.
    private nonisolated static func repositoryLinkRemotePriority(_ remoteName: String) -> Int {
        switch remoteName.lowercased() {
        case "origin":
            return 0
        case "upstream":
            return 1
        default:
            return 2
        }
    }

    /// Converts supported Git remote URL forms into sanitized HTTP(S) URLs.
    private nonisolated static func normalizedBrowsableRepositoryURL(from remoteURL: String) -> URL? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 * 1024 else { return nil }
        guard !trimmed.contains("::") else { return nil }

        if !trimmed.contains("://") {
            return normalizedBrowsableSCPRepositoryURL(from: trimmed)
        }

        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "ssh", "git"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              let displayName = repositoryLinkDisplayName(from: components.path) else {
            return nil
        }

        components.scheme = switch scheme {
        case "ssh", "git": repositoryLinkIsPrivateIPv4(host) ? "http" : "https"
        default: scheme
        }
        if scheme == "ssh" || scheme == "git" {
            components.port = nil
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = "/\(displayName)"
        return components.url
    }

    /// Converts SCP-style `user@host:path` remotes into sanitized HTTPS URLs.
    private nonisolated static func normalizedBrowsableSCPRepositoryURL(from remoteURL: String) -> URL? {
        let parts = remoteURL.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty,
              !remoteURL.contains("?"),
              !remoteURL.contains("#") else {
            return nil
        }

        let address = String(parts[0])
        guard repositoryLinkSCPAddressIsUnambiguous(address) else {
            return nil
        }
        let host = address.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? ""
        guard !host.isEmpty,
              !host.contains("/"),
              !host.contains("\\"),
              let displayName = repositoryLinkDisplayName(from: String(parts[1])) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = repositoryLinkIsPrivateIPv4(host) ? "http" : "https"
        components.host = host
        components.path = "/\(displayName)"
        return components.url
    }

    /// Whether a host is a literal IPv4 address in one of the RFC 1918 ranges.
    private nonisolated static func repositoryLinkIsPrivateIPv4(_ host: String) -> Bool {
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }

        let octets = components.compactMap { component -> Int? in
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return nil
            }
            return Int(component)
        }
        guard octets.count == 4,
              octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }

        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }

    /// Whether an SCP address is distinct from a bare URI scheme prefix.
    private nonisolated static func repositoryLinkSCPAddressIsUnambiguous(_ address: String) -> Bool {
        let components = address.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        if components.count == 2 {
            return !components[0].isEmpty && !components[1].isEmpty
        }
        let knownURISchemes = ["file", "ftp", "git", "http", "https", "ssh", "svn"]
        guard !address.isEmpty,
              !knownURISchemes.contains(address.lowercased()),
              address.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }) else {
            return false
        }
        return true
    }

    /// Removes separators and a trailing `.git` from a non-empty repository path.
    private nonisolated static func repositoryLinkDisplayName(from rawPath: String) -> String? {
        var path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty, path.utf8.count <= 4 * 1024 else { return nil }
        if path.hasSuffix(".git") {
            path.removeLast(4)
        }
        return path.isEmpty ? nil : path
    }
}
