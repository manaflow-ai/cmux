import Foundation

extension CmuxUseSupport {
    static func stripControlCharacters(_ raw: String) -> String {
        String(raw.unicodeScalars.filter { scalar in
            (scalar.value >= 0x20 && scalar.value != 0x7F) || scalar.value == 0x09
        })
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

        let home = homeURL.standardizedFileURL
        var resolved = home
        for part in parts {
            resolved.appendPathComponent(part, isDirectory: true)
        }
        let standardized = resolved.standardizedFileURL
        let homePrefix = home.path.hasSuffix("/") ? home.path : "\(home.path)/"
        guard standardized.path.hasPrefix(homePrefix) else {
            throw CLIError(message: "cmux.extension.json install.path must resolve inside the user's home directory")
        }
        return standardized
    }
}
