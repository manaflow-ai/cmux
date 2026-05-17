import Foundation

extension CmuxUseSupport {
    private static let sensitiveHomeInstallPathPrefixes: [[String]] = [
        [".1password"],
        [".aws"],
        [".azure"],
        [".config"],
        [".docker"],
        [".gnupg"],
        [".gpg"],
        [".kube"],
        [".local", "share", "keyrings"],
        [".netrc"],
        [".npmrc"],
        [".pypirc"],
        [".ssh"],
    ]

    static func stripControlCharacters(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { scalar in
            !isUnsafeManifestScalar(scalar)
        })
    }

    private static func isUnsafeManifestScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value == 0x09 {
            return false
        }
        if value < 0x20 || (value >= 0x7F && value <= 0x9F) {
            return true
        }

        switch value {
        case 0x061C,
             0x200E...0x200F,
             0x202A...0x202E,
             0x2066...0x206F:
            return true
        default:
            return false
        }
    }

    static func validatedManifestPathComponent(_ raw: String, fieldName: String) throws -> String {
        let value = stripControlCharacters(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value != ".",
              value != "..",
              value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw CLIError(message: "cmux.extension.json \(fieldName) must contain only letters, numbers, '.', '_' or '-'")
        }
        return value
    }

    static func manifestInstallPathURL(_ raw: String, homeURL: URL) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: "cmux.extension.json install.path must be non-empty")
        }

        let relativePath: String
        if trimmed.hasPrefix("~/") {
            relativePath = String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix("$HOME/") {
            relativePath = String(trimmed.dropFirst("$HOME/".count))
        } else {
            throw CLIError(message: "cmux.extension.json install.path must start with ~/ or $HOME/ and include a subdirectory")
        }

        let parts = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CLIError(message: "cmux.extension.json install.path must include a subdirectory and must not contain '.' or '..'")
        }
        if let sensitivePrefix = sensitiveHomeInstallPathPrefix(in: parts) {
            throw CLIError(message: "cmux.extension.json install.path must not target sensitive home directory ~/\(sensitivePrefix)")
        }

        let home = homeURL.standardizedFileURL.resolvingSymlinksInPath()
        var resolved = home
        for part in parts {
            resolved.appendPathComponent(part, isDirectory: true)
        }
        let standardized = resolved.standardizedFileURL.resolvingSymlinksInPath()
        guard let resolvedParts = relativeHomePathComponents(for: standardized, home: home) else {
            throw CLIError(message: "cmux.extension.json install.path must resolve inside the user's home directory")
        }
        guard !resolvedParts.isEmpty else {
            throw CLIError(message: "cmux.extension.json install.path must resolve to a subdirectory inside the user's home directory")
        }
        if let sensitivePrefix = sensitiveHomeInstallPathPrefix(in: resolvedParts) {
            throw CLIError(message: "cmux.extension.json install.path must not target sensitive home directory ~/\(sensitivePrefix)")
        }
        return standardized
    }

    private static func relativeHomePathComponents(for url: URL, home: URL) -> [String]? {
        let path = url.path
        let homePath = home.path
        if path == homePath {
            return []
        }

        let homePrefix = homePath.hasSuffix("/") ? homePath : "\(homePath)/"
        guard path.hasPrefix(homePrefix) else {
            return nil
        }

        let relativePath = String(path.dropFirst(homePrefix.count))
        return relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func sensitiveHomeInstallPathPrefix(in parts: [String]) -> String? {
        let lowercasedParts = parts.map { $0.lowercased() }
        for prefix in sensitiveHomeInstallPathPrefixes where lowercasedParts.starts(with: prefix) {
            return prefix.joined(separator: "/")
        }
        return nil
    }
}
