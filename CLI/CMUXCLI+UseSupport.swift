import Foundation
import CMUXRepoDetection

nonisolated struct CmuxUseRepository: Equatable {
    let owner: String
    let name: String

    var fullName: String { "\(owner)/\(name)" }
    var cloneURL: String { "https://github.com/\(fullName).git" }
    var webURL: String { "https://github.com/\(fullName)" }
}

nonisolated struct CmuxUseLaunchCommand: Equatable {
    let command: String
    let source: String
}

nonisolated struct CmuxUseManifest: Equatable {
    let id: String
    let name: String
    let publisher: String
    let version: String
    let generated: Bool
    let main: String?
    let engineRequirement: String?
    let permissions: [String]
    let installPath: String?
    let installCommand: String?
    let command: String?
    let commandSource: String?
    let sourceFile: String
}

nonisolated enum CmuxUseSupport {
    private static let manifestCommandKeys = ["use", "launch", "start", "run", "command"]
    private static let manifestCommandContainers = ["scripts", "commands", "cmux"]

    static func parseGitHubRepository(_ raw: String) throws -> CmuxUseRepository {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: "cmux use requires a GitHub repository")
        }

        if let scpStylePath = gitHubSCPStylePath(trimmed) {
            return try parseGitHubPath(scpStylePath)
        }

        let candidate: String = {
            let lowercased = trimmed.lowercased()
            if lowercased.hasPrefix("github.com/") || lowercased.hasPrefix("www.github.com/") {
                return "https://\(trimmed)"
            }
            return trimmed
        }()

        if let components = URLComponents(string: candidate),
           let host = components.host?.lowercased(),
           host == "github.com" || host == "www.github.com" {
            return try parseGitHubPath(components.path)
        }

        return try parseGitHubPath(trimmed)
    }

    static func gitRemote(_ remote: String, matches repository: CmuxUseRepository) -> Bool {
        guard let parsed = try? parseGitHubRepository(remote) else {
            return false
        }
        return parsed.owner.caseInsensitiveCompare(repository.owner) == .orderedSame
            && parsed.name.caseInsensitiveCompare(repository.name) == .orderedSame
    }

    static func managedSourceCheckoutURL(
        for repository: CmuxUseRepository,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        return homeURL
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("extension-sources", isDirectory: true)
            .appendingPathComponent("github.com", isDirectory: true)
            .appendingPathComponent(repository.owner, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
    }

    static func generatedManifestURL(
        for repository: CmuxUseRepository,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeURL
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("extension-metadata", isDirectory: true)
            .appendingPathComponent("github.com", isDirectory: true)
            .appendingPathComponent(repository.owner, isDirectory: true)
            .appendingPathComponent(repository.name, isDirectory: true)
            .appendingPathComponent("cmux.extension.generated.json", isDirectory: false)
    }

    static func writeGeneratedManifest(_ manifest: CmuxUseManifest, repository: CmuxUseRepository) throws -> URL {
        let url = generatedManifestURL(for: repository)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        var object: [String: Any] = [
            "id": manifest.id,
            "name": manifest.name,
            "publisher": manifest.publisher,
            "version": manifest.version,
            "repository": repository.webURL,
            "generated": true,
            "permissions": manifest.permissions,
        ]
        var install: [String: Any] = [:]
        if let installPath = manifest.installPath {
            install["path"] = installPath
        }
        if let installCommand = manifest.installCommand {
            install["command"] = installCommand
        }
        if !install.isEmpty {
            object["install"] = install
        }
        if let command = manifest.command {
            object["command"] = command
        }

        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return url
    }

    static func manifestInstallURL(
        for manifest: CmuxUseManifest,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        if let installPath = manifest.installPath {
            return try manifestInstallPathURL(installPath, homeURL: homeURL)
        }

        return homeURL
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent(manifest.id, isDirectory: true)
            .appendingPathComponent(manifest.version, isDirectory: true)
    }

    static func loadManifest(in checkoutURL: URL, repository: CmuxUseRepository) throws -> CmuxUseManifest? {
        for manifestName in ["cmux.extension.json", "cmux-extension.json"] {
            let manifestURL = checkoutURL.appendingPathComponent(manifestName, isDirectory: false)
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            let data = try Data(contentsOf: manifestURL)
            guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CLIError(message: "\(manifestName) must contain a JSON object")
            }

            let nestedCommand = manifestCommand(in: manifest)
            let install = manifest["install"] as? [String: Any]
            let installPath = install.flatMap {
                optionalManifestString(in: $0, keys: ["path", "directory", "target"])
            }
            let installCommand = install.flatMap {
                optionalManifestString(in: $0, keys: ["command", "run", "setup"])
            }
            let main = optionalManifestString(in: manifest, key: "main")
            return CmuxUseManifest(
                id: try validatedManifestPathComponent(
                    optionalManifestString(in: manifest, key: "id") ?? inferredExtensionID(for: repository),
                    fieldName: "id"
                ),
                name: optionalManifestString(in: manifest, key: "name") ?? repository.name,
                publisher: optionalManifestString(in: manifest, key: "publisher") ?? repository.owner,
                version: try validatedManifestPathComponent(
                    optionalManifestString(in: manifest, key: "version") ?? "0.0.0-git",
                    fieldName: "version"
                ),
                generated: false,
                main: main,
                engineRequirement: (manifest["engines"] as? [String: Any]).flatMap { optionalManifestString(in: $0, key: "cmux") },
                permissions: stringArray(in: manifest, key: "permissions"),
                installPath: installPath,
                installCommand: installCommand,
                command: nestedCommand?.command ?? main.map { "node \(shellSingleQuoted($0))" },
                commandSource: nestedCommand.map { "\(manifestName):\($0.source)" }
                    ?? main.map { _ in "\(manifestName):main" },
                sourceFile: manifestName
            )
        }

        return nil
    }

    static func generateManifest(in checkoutURL: URL, repository: CmuxUseRepository) -> CmuxUseManifest {
        let hints = generatedManifestHints(in: checkoutURL)
        let generatedVersion = hints.version ?? "0.0.0-generated"
        let commandSource = hints.launchCommand.map { "generated:\($0.source)" }

        return CmuxUseManifest(
            id: inferredExtensionID(for: repository),
            name: hints.displayName ?? repository.name,
            publisher: repository.owner,
            version: generatedVersion,
            generated: true,
            main: nil,
            engineRequirement: nil,
            permissions: hints.permissions,
            installPath: hints.installPath,
            installCommand: hints.installCommand,
            command: hints.launchCommand?.command,
            commandSource: commandSource,
            sourceFile: "generated"
        )
    }

    static func detectLaunchCommand(in checkoutURL: URL, manifest: CmuxUseManifest? = nil) throws -> CmuxUseLaunchCommand? {
        if let manifest,
           let command = manifest.command,
           let source = manifest.commandSource {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : CmuxUseLaunchCommand(command: trimmed, source: source)
        }

        return runtimeLaunchCommand(in: checkoutURL)
    }

    private static func parseGitHubPath(_ rawPath: String) throws -> CmuxUseRepository {
        let cleanedPath = rawPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let withoutSuffix = cleanedPath.hasSuffix(".git")
            ? String(cleanedPath.dropLast(".git".count))
            : cleanedPath
        let parts = withoutSuffix.split(separator: "/").map(String.init)
        guard parts.count >= 2 else {
            throw CLIError(message: "Usage: cmux use <owner/repo|github-url>")
        }

        let owner = parts[0]
        let name = parts[1]
        guard isValidGitHubPathComponent(owner), isValidGitHubPathComponent(name) else {
            throw CLIError(message: "Invalid GitHub repository: \(rawPath)")
        }

        return CmuxUseRepository(owner: owner, name: name)
    }

    private static func gitHubSCPStylePath(_ raw: String) -> String? {
        guard let separator = raw.firstIndex(of: ":") else {
            return nil
        }
        let endpoint = String(raw[..<separator])
        guard endpoint.caseInsensitiveCompare("git@github.com") == .orderedSame else {
            return nil
        }
        return String(raw[raw.index(after: separator)...])
    }

    private static func isValidGitHubPathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private static func manifestCommand(in manifest: [String: Any]) -> CmuxUseLaunchCommand? {
        if let command = stringValue(in: manifest, keys: manifestCommandKeys) {
            return CmuxUseLaunchCommand(command: command, source: "manifest")
        }

        for container in manifestCommandContainers {
            guard let nested = manifest[container] as? [String: Any],
                  let command = stringValue(in: nested, keys: manifestCommandKeys) else {
                continue
            }
            return CmuxUseLaunchCommand(command: command, source: "manifest:\(container)")
        }

        return nil
    }

    private static func optionalManifestString(in object: [String: Any], key: String) -> String? {
        guard let raw = object[key] as? String else { return nil }
        let trimmed = stripControlCharacters(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func optionalManifestString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = optionalManifestString(in: object, key: key) {
                return value
            }
        }
        return nil
    }

    private static func stringArray(in object: [String: Any], key: String) -> [String] {
        guard let values = object[key] as? [Any] else { return [] }
        return values.compactMap { value in
            guard let string = value as? String else { return nil }
            let trimmed = stripControlCharacters(string).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func inferredExtensionID(for repository: CmuxUseRepository) -> String {
        "\(sanitizeExtensionIDComponent(repository.owner)).\(sanitizeExtensionIDComponent(repository.name))"
    }

    private static func sanitizeExtensionIDComponent(_ value: String) -> String {
        let allowedPunctuation = CharacterSet(charactersIn: "-_")
        let scalars = value.lowercased().unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || allowedPunctuation.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return sanitized.isEmpty ? "extension" : sanitized
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func stringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let raw = object[key] as? String else { continue }
            let trimmed = stripControlCharacters(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

}
