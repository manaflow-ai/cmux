import Foundation
import CMUXRepoDetection

nonisolated struct CmuxGeneratedManifestHints: Equatable {
    let displayName: String?
    let version: String?
    let installPath: String?
    let installCommand: String?
    let launchCommand: CmuxUseLaunchCommand?
    let permissions: [String]
}

extension CmuxUseSupport {
    static func generatedManifestHints(in checkoutURL: URL) -> CmuxGeneratedManifestHints {
        let package = CMUXRepoDetection.packageJSON(in: checkoutURL)
        let displayName = sanitizedString(package?["name"]).flatMap(packageDisplayName)
        let version = sanitizedString(package?["version"])
        let installPath = inferredInstallPath(in: checkoutURL)
        let installCommand = inferredInstallCommand(in: checkoutURL, package: package)
        let launchCommand = runtimeLaunchCommand(in: checkoutURL, package: package)
        let permissions = inferredPermissions(
            installPath: installPath,
            command: launchCommand?.command ?? installCommand
        )

        return CmuxGeneratedManifestHints(
            displayName: displayName,
            version: version,
            installPath: installPath,
            installCommand: installCommand,
            launchCommand: launchCommand,
            permissions: permissions
        )
    }

    static func runtimeLaunchCommand(in checkoutURL: URL) -> CmuxUseLaunchCommand? {
        runtimeLaunchCommand(in: checkoutURL, package: nil)
    }

    private static func runtimeLaunchCommand(
        in checkoutURL: URL,
        package: [String: Any]?
    ) -> CmuxUseLaunchCommand? {
        for scriptName in ["launch.sh", "use.sh", "start.sh", "run.sh"] {
            let scriptURL = checkoutURL.appendingPathComponent(scriptName, isDirectory: false)
            if FileManager.default.fileExists(atPath: scriptURL.path) {
                return CmuxUseLaunchCommand(
                    command: shellScriptCommand(for: scriptURL, relativeName: scriptName),
                    source: scriptName
                )
            }
        }

        if let packageCommand = packageJSONLaunchCommand(in: checkoutURL, package: package) {
            return CmuxUseLaunchCommand(command: packageCommand.command, source: packageCommand.source)
        }

        if let makeCommand = CMUXRepoDetection.makefileLaunchCommand(in: checkoutURL) {
            return CmuxUseLaunchCommand(command: makeCommand.command, source: makeCommand.source)
        }

        return nil
    }

    private static func packageJSONLaunchCommand(
        in checkoutURL: URL,
        package providedPackage: [String: Any]?
    ) -> CMUXDetectedLaunchCommand? {
        guard let package = providedPackage ?? CMUXRepoDetection.packageJSON(in: checkoutURL),
              let scripts = package["scripts"] as? [String: Any] else {
            return nil
        }

        for script in ["use", "cmux", "start", "dev"] {
            guard scripts[script] is String else { continue }
            return CMUXDetectedLaunchCommand(
                command: "\(CMUXRepoDetection.packageManagerCommand(in: checkoutURL)) run \(script)",
                source: "package.json:scripts.\(script)"
            )
        }
        return nil
    }

    private static func packageDisplayName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: "/").last.map(String.init)
    }

    private static func inferredInstallPath(in checkoutURL: URL) -> String? {
        for filename in ["setup.sh", "install.sh"] {
            let url = checkoutURL.appendingPathComponent(filename, isDirectory: false)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let value = firstInstallDirectoryAssignment(in: contents) {
                return normalizedManifestPath(value)
            }
        }

        let readmeURL = checkoutURL.appendingPathComponent("README.md", isDirectory: false)
        guard let readme = try? String(contentsOf: readmeURL, encoding: .utf8) else { return nil }
        for pattern in [
            #"(?m)git\s+clone\s+\S+\s+((?:\$HOME|~)/[^\s`"']+)"#,
            #"(?i)(?:clone|install).{0,120}\s+to\s+[`"']?((?:\$HOME|~)/[^`"'\s]+)"#,
        ] {
            if let value = firstRegexCapture(pattern: pattern, in: readme) {
                return normalizedManifestPath(value)
            }
        }
        return nil
    }

    private static func firstInstallDirectoryAssignment(in contents: String) -> String? {
        let assignmentPattern = #"^(?:export\s+)?(?:EXPECTED_DIR|INSTALL_DIR|TARGET_DIR|CONFIG_DIR)\s*=\s*["']((?:\$HOME|~)/[^"']+)["']"#
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            if let value = firstRegexCapture(pattern: assignmentPattern, in: line) {
                return value
            }
        }
        return nil
    }

    private static func inferredInstallCommand(in checkoutURL: URL, package: [String: Any]?) -> String? {
        for scriptName in ["setup.sh", "install.sh"] {
            let scriptURL = checkoutURL.appendingPathComponent(scriptName, isDirectory: false)
            if FileManager.default.fileExists(atPath: scriptURL.path) {
                return shellScriptCommand(for: scriptURL, relativeName: scriptName)
            }
        }

        guard let scripts = package?["scripts"] as? [String: Any] else { return nil }
        for script in ["setup", "install", "postinstall"] where scripts[script] is String {
            return "\(CMUXRepoDetection.packageManagerCommand(in: checkoutURL)) run \(script)"
        }
        return nil
    }

    private static func inferredPermissions(installPath: String?, command: String?) -> [String] {
        var permissions: [String] = []
        if let installPath {
            permissions.append("filesystem:\(installPath)")
        }
        if let command,
           let executable = command.split(separator: " ").first {
            permissions.append("shell:\(executable)")
        }
        permissions.append("network:github")
        return permissions
    }

    private static func normalizedManifestPath(_ raw: String) -> String {
        var value = stripControlCharacters(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    private static func firstRegexCapture(pattern: String, in contents: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        guard let match = regex.firstMatch(in: contents, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: contents) else {
            return nil
        }
        let value = String(contents[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func shellScriptCommand(for scriptURL: URL, relativeName: String) -> String {
        let relativePath = "./\(relativeName)"
        if FileManager.default.isExecutableFile(atPath: scriptURL.path) {
            return relativePath
        }

        let firstLine = (try? String(contentsOf: scriptURL, encoding: .utf8))?
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)
        switch shebangInterpreter(from: firstLine) {
        case "bash":
            return "bash \(relativePath)"
        case "zsh":
            return "zsh \(relativePath)"
        default:
            return "sh \(relativePath)"
        }
    }

    private static func shebangInterpreter(from firstLine: String?) -> String? {
        guard var shebang = firstLine?.trimmingCharacters(in: .whitespacesAndNewlines),
              shebang.hasPrefix("#!") else {
            return nil
        }
        shebang.removeFirst(2)

        let tokens = shebang.split(whereSeparator: { $0.isWhitespace })
        guard let command = tokens.first else { return nil }
        let commandName = pathBasename(String(command)).lowercased()
        if commandName != "env" {
            return commandName
        }

        for token in tokens.dropFirst() {
            let value = String(token)
            if value.hasPrefix("-") || value.contains("=") {
                continue
            }
            return pathBasename(value).lowercased()
        }
        return nil
    }

    private static func pathBasename(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    private static func sanitizedString(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let trimmed = stripControlCharacters(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
