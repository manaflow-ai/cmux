import Foundation

/// Lexically canonicalizes transcript artifact paths without filesystem access.
struct ChatArtifactPathNormalizer: Sendable {
    private let workingDirectory: String?

    /// Creates a normalizer for one session working directory.
    ///
    /// - Parameter workingDirectory: The absolute session directory used to
    ///   resolve structured relative paths and infer the session user's home.
    init(workingDirectory: String?) {
        self.workingDirectory = workingDirectory
    }

    /// Normalizes a path supplied by a structured transcript field.
    ///
    /// Relative structured paths resolve against the session directory. When
    /// the directory is unavailable they remain relative, preserving the
    /// existing unresolved-path audit behavior.
    ///
    /// - Parameter path: The structured path value.
    /// - Returns: The canonical path, or `nil` for excluded pseudo-filesystems.
    func structuredPath(_ path: String) -> String? {
        normalized(path, permitsRelative: true)
    }

    /// Normalizes an absolute path detected in free transcript text.
    ///
    /// - Parameter path: A detector token beginning with `/` or `~/`, or a
    ///   file URL unwrapped by the detector.
    /// - Returns: The canonical absolute path, or `nil` when the token is
    ///   relative, uses another URL scheme, or names an excluded pseudo-file.
    func freeTextPath(_ path: String) -> String? {
        normalized(path, permitsRelative: false)
    }

    /// Reports whether a detector token can become an absolute free-text path.
    ///
    /// - Parameter path: A token returned by ``TerminalArtifactPathDetector``.
    /// - Returns: `true` for slash-absolute and home-relative tokens.
    static func isAbsoluteFreeTextCandidate(_ path: String) -> Bool {
        path.hasPrefix("/") || path == "~" || path.hasPrefix("~/")
    }

    private func normalized(_ path: String, permitsRelative: Bool) -> String? {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            guard trimmed.hasPrefix("file://"),
                  let url = URL(string: trimmed),
                  url.isFileURL else { return nil }
            trimmed = url.path
        }

        let absolute: String
        if trimmed == "~" || trimmed.hasPrefix("~/") {
            let suffix = trimmed == "~" ? "" : String(trimmed.dropFirst(2))
            absolute = suffix.isEmpty
                ? inferredHomeDirectory()
                : (inferredHomeDirectory() as NSString).appendingPathComponent(suffix)
        } else if trimmed.hasPrefix("/") {
            absolute = trimmed
        } else if permitsRelative, let workingDirectory {
            let cwd = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard cwd.hasPrefix("/") else { return trimmed }
            absolute = (cwd as NSString).appendingPathComponent(trimmed)
        } else if permitsRelative {
            return trimmed
        } else {
            return nil
        }

        // Purely lexical normalization keeps deleted and moved artifacts in
        // the gallery instead of consulting the current filesystem state.
        var components: [String] = []
        for component in absolute.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(String(component))
            }
        }
        var standardized = "/" + components.joined(separator: "/")
        for alias in ["/tmp", "/var", "/etc"] {
            if standardized == alias || standardized.hasPrefix(alias + "/") {
                standardized = "/private" + standardized
                break
            }
        }
        guard !Self.isExcludedSystemPath(standardized) else { return nil }
        return standardized
    }

    private func inferredHomeDirectory() -> String {
        if let workingDirectory {
            let components = workingDirectory.split(separator: "/")
            if components.count >= 2, components[0] == "Users" {
                return "/Users/\(components[1])"
            }
        }
        return NSHomeDirectory()
    }

    private static func isExcludedSystemPath(_ path: String) -> Bool {
        ["/dev", "/proc", "/sys"].contains { prefix in
            path == prefix || path.hasPrefix(prefix + "/")
        }
    }
}
