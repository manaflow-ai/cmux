import Foundation

public struct CMUXDetectedLaunchCommand: Equatable {
    public let command: String
    public let source: String

    public init(command: String, source: String) {
        self.command = command
        self.source = source
    }
}

public struct CMUXGeneratedManifestHints: Equatable {
    public let displayName: String?
    public let version: String?
    public let installPath: String?
    public let installCommand: String?
    public let launchCommand: CMUXDetectedLaunchCommand?
    public let permissions: [String]

    public init(
        displayName: String?,
        version: String?,
        installPath: String?,
        installCommand: String?,
        launchCommand: CMUXDetectedLaunchCommand?,
        permissions: [String]
    ) {
        self.displayName = displayName
        self.version = version
        self.installPath = installPath
        self.installCommand = installCommand
        self.launchCommand = launchCommand
        self.permissions = permissions
    }
}

public enum CMUXRepoDetection {
    public static func generatedManifestHints(in checkoutURL: URL) -> CMUXGeneratedManifestHints {
        let package = packageJSON(in: checkoutURL)
        let displayName = stringValue(package?["name"]).flatMap(packageDisplayName)
        let version = stringValue(package?["version"])
        let installPath = inferredInstallPath(in: checkoutURL)
        let installCommand = inferredInstallCommand(in: checkoutURL, package: package)
        let launchCommand = launchCommand(in: checkoutURL, package: package)
        let permissions = inferredPermissions(
            installPath: installPath,
            command: launchCommand?.command ?? installCommand
        )

        return CMUXGeneratedManifestHints(
            displayName: displayName,
            version: version,
            installPath: installPath,
            installCommand: installCommand,
            launchCommand: launchCommand,
            permissions: permissions
        )
    }

    public static func launchCommand(in checkoutURL: URL) -> CMUXDetectedLaunchCommand? {
        launchCommand(in: checkoutURL, package: nil)
    }

    public static func packageJSONLaunchCommand(in checkoutURL: URL) -> CMUXDetectedLaunchCommand? {
        packageJSONLaunchCommand(in: checkoutURL, package: nil)
    }

    public static func packageDisplayName(_ raw: String) -> String? {
        let trimmed = stripControlCharacters(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: "/").last.map(String.init)
    }

    static func launchCommand(
        in checkoutURL: URL,
        package: [String: Any]?
    ) -> CMUXDetectedLaunchCommand? {
        for scriptName in ["launch.sh", "use.sh", "start.sh", "run.sh"] {
            let scriptURL = checkoutURL.appendingPathComponent(scriptName, isDirectory: false)
            if FileManager.default.fileExists(atPath: scriptURL.path) {
                return CMUXDetectedLaunchCommand(
                    command: shellScriptCommand(for: scriptURL, relativeName: scriptName),
                    source: scriptName
                )
            }
        }

        if let packageCommand = packageJSONLaunchCommand(in: checkoutURL, package: package) {
            return packageCommand
        }

        return makefileLaunchCommand(in: checkoutURL)
    }

    static func packageJSONLaunchCommand(
        in checkoutURL: URL,
        package providedPackage: [String: Any]?
    ) -> CMUXDetectedLaunchCommand? {
        guard let package = providedPackage ?? packageJSON(in: checkoutURL),
              let scripts = package["scripts"] as? [String: Any] else {
            return nil
        }

        for script in ["use", "cmux", "start", "dev"] {
            guard scripts[script] is String else { continue }
            return CMUXDetectedLaunchCommand(
                command: "\(packageManagerCommand(in: checkoutURL)) run \(script)",
                source: "package.json:scripts.\(script)"
            )
        }
        return nil
    }

    public static func packageJSON(in checkoutURL: URL) -> [String: Any]? {
        let packageURL = checkoutURL.appendingPathComponent("package.json", isDirectory: false)
        guard let data = try? Data(contentsOf: packageURL),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return package
    }

    public static func packageManagerCommand(in checkoutURL: URL) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: checkoutURL.appendingPathComponent("bun.lockb").path)
            || fm.fileExists(atPath: checkoutURL.appendingPathComponent("bun.lock").path) {
            return "bun"
        }
        if fm.fileExists(atPath: checkoutURL.appendingPathComponent("pnpm-lock.yaml").path) {
            return "pnpm"
        }
        if fm.fileExists(atPath: checkoutURL.appendingPathComponent("yarn.lock").path) {
            return "yarn"
        }
        return "npm"
    }

    public static func makefileLaunchCommand(in checkoutURL: URL) -> CMUXDetectedLaunchCommand? {
        for filename in ["Makefile", "makefile"] {
            let makefileURL = checkoutURL.appendingPathComponent(filename, isDirectory: false)
            guard let contents = try? String(contentsOf: makefileURL, encoding: .utf8) else { continue }
            for target in ["start", "run", "use"] where makefile(contents, hasTarget: target) {
                return CMUXDetectedLaunchCommand(command: "make \(target)", source: "\(filename):\(target)")
            }
        }
        return nil
    }

    public static func makefile(_ contents: String, hasTarget target: String) -> Bool {
        contents.split(separator: "\n", omittingEmptySubsequences: false).contains { rawLine in
            let line = String(rawLine)
            guard !line.hasPrefix("\t"), !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else {
                return false
            }
            return line.range(of: #"^\#(target):(\s|$)"#, options: .regularExpression) != nil
        }
    }

    private static func inferredInstallPath(in checkoutURL: URL) -> String? {
        for filename in ["setup.sh", "install.sh"] {
            let url = checkoutURL.appendingPathComponent(filename, isDirectory: false)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let value = firstRegexCapture(
                pattern: #"(?m)(?:EXPECTED_DIR|INSTALL_DIR|TARGET_DIR|CONFIG_DIR)\s*=\s*["']((?:\$HOME|~)/[^"']+)["']"#,
                in: contents
            ) {
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

    private static func inferredInstallCommand(in checkoutURL: URL, package: [String: Any]?) -> String? {
        for scriptName in ["setup.sh", "install.sh"] {
            let scriptURL = checkoutURL.appendingPathComponent(scriptName, isDirectory: false)
            if FileManager.default.fileExists(atPath: scriptURL.path) {
                return shellScriptCommand(for: scriptURL, relativeName: scriptName)
            }
        }

        guard let scripts = package?["scripts"] as? [String: Any] else { return nil }
        for script in ["setup", "install", "postinstall"] where scripts[script] is String {
            return "\(packageManagerCommand(in: checkoutURL)) run \(script)"
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
        let prefix = firstLine?.lowercased() ?? ""
        if prefix.contains("bash") {
            return "bash \(relativePath)"
        }
        if prefix.contains("zsh") {
            return "zsh \(relativePath)"
        }
        return "sh \(relativePath)"
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let trimmed = stripControlCharacters(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stripControlCharacters(_ value: String) -> String {
        let disallowed = CharacterSet.controlCharacters.union(.illegalCharacters)
        return String(value.unicodeScalars.filter { !disallowed.contains($0) })
    }
}
