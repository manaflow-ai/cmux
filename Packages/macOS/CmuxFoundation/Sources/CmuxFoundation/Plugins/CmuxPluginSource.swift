import Foundation

/// Where `cmux plugin install` clones a plugin from.
///
/// `owner/repo` and `owner/repo/sub/dir` are GitHub shorthands. Anything
/// that looks like a URL, an SCP-style `user@host:path`, or a local path is
/// passed to `git clone` unchanged, following the cmux-tui manager's rules:
/// HTTP(S) sources with credentials, a query, or a fragment are rejected so
/// tokens never reach the process table.
public struct CmuxPluginSource: Equatable, Sendable {
    public let cloneURL: String
    /// Plugin directory inside the checkout, if not the repository root.
    public let subdirectory: String?

    public init(cloneURL: String, subdirectory: String? = nil) {
        self.cloneURL = cloneURL
        self.subdirectory = subdirectory
    }

    public static func parse(_ raw: String, subdirectory explicitSubdirectory: String? = nil) throws -> CmuxPluginSource {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("-") else {
            throw CmuxPluginManifestError("plugin source must be a git URL or owner/repo[/subdir]")
        }
        if let explicitSubdirectory {
            try validateSubdirectory(explicitSubdirectory)
        }
        if value.contains("://") {
            if let components = URLComponents(string: value),
               ["http", "https"].contains(components.scheme?.lowercased() ?? "") {
                guard components.user == nil,
                      components.password == nil,
                      components.query == nil,
                      components.fragment == nil else {
                    throw CmuxPluginManifestError(
                        "HTTP sources must not contain credentials, a query, or a fragment; use a git credential helper or SSH"
                    )
                }
            }
            return CmuxPluginSource(cloneURL: value, subdirectory: explicitSubdirectory)
        }
        if let at = value.firstIndex(of: "@"), value[..<at].contains(":") {
            throw CmuxPluginManifestError("plugin sources must not include credentials; use a git credential helper or SSH")
        }
        if value.hasPrefix("/") || value.hasPrefix(".") || value.hasPrefix("~") {
            throw CmuxPluginManifestError("local plugin sources are not supported by install; use cmux plugin link")
        }
        if value.contains(":") {
            return CmuxPluginSource(cloneURL: value, subdirectory: explicitSubdirectory)
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard parts.count >= 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              parts[0...1].allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            throw CmuxPluginManifestError("plugin source must be a git URL or owner/repo[/subdir]")
        }
        let shorthandSubdirectory = parts.count > 2 ? parts[2...].joined(separator: "/") : nil
        guard shorthandSubdirectory == nil || explicitSubdirectory == nil else {
            throw CmuxPluginManifestError("give the subdirectory either in owner/repo/subdir or with --subdir, not both")
        }
        let repository = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return CmuxPluginSource(
            cloneURL: "https://github.com/\(parts[0])/\(repository).git",
            subdirectory: shorthandSubdirectory ?? explicitSubdirectory
        )
    }

    static func validateSubdirectory(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: true)
        guard !value.hasPrefix("/"),
              !parts.isEmpty,
              parts.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw CmuxPluginManifestError("--subdir must be a relative path inside the repository")
        }
    }
}
