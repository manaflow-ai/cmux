import Foundation

extension CmuxUseSupport {
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

        let home = homeURL.standardizedFileURL.resolvingSymlinksInPath()
        var resolved = home
        for part in parts {
            resolved.appendPathComponent(part, isDirectory: true)
        }
        let standardized = resolved.standardizedFileURL.resolvingSymlinksInPath()
        let homePrefix = home.path.hasSuffix("/") ? home.path : "\(home.path)/"
        guard standardized.path.hasPrefix(homePrefix) else {
            throw CLIError(message: "cmux.extension.json install.path must resolve inside the user's home directory")
        }
        return standardized
    }
}
