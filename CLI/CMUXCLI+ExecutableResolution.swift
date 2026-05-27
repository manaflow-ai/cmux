import Foundation

extension CMUXCLI {
    func missingProviderExecutableMessage(displayName: String, executableName: String) -> String {
        let format = String(
            localized: "agentSession.error.missingProviderExecutable",
            defaultValue: "%@ was not found. Install it and make sure \"%@\" is available on PATH."
        )
        return String(format: format, displayName, executableName)
    }

    func isBundledProviderExecutable(at path: String) -> Bool {
        guard let bundledBinDirectory = bundledProviderBinDirectory() else { return false }
        let candidate = URL(fileURLWithPath: path, isDirectory: false)
            .standardizedFileURL
            .path
        return candidate.hasPrefix(bundledBinDirectory + "/")
    }

    func isCmuxClaudeWrapper(at path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let prefixData = data.prefix(512)
        guard let prefix = String(data: prefixData, encoding: .utf8) else { return false }
        return prefix.contains("cmux claude wrapper - injects hooks and session tracking")
    }

    func resolveExecutableInSearchPath(
        _ name: String,
        searchPath: String?,
        skip: ((String) -> Bool)? = nil
    ) -> String? {
        let entries = providerExecutableSearchDirectories(searchPath: searchPath)
        for entry in entries where !entry.isEmpty {
            let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .path
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            guard !isBundledProviderExecutable(at: candidate) else { continue }
            if let skip, skip(candidate) { continue }
            return candidate
        }
        return nil
    }

    func resolveClaudeExecutable(configuredCandidates: [String?], searchPath: String?) -> String? {
        for raw in configuredCandidates {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: trimmed),
                  !isBundledProviderExecutable(at: trimmed),
                  !isCmuxClaudeWrapper(at: trimmed) else { continue }
            return URL(fileURLWithPath: trimmed, isDirectory: false).standardizedFileURL.path
        }

        return resolveClaudeExecutable(searchPath: searchPath)
    }

    func resolveClaudeExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath(
            "claude",
            searchPath: searchPath,
            skip: { self.isCmuxClaudeWrapper(at: $0) }
        )
    }

    func resolveCodexExecutable(searchPath: String?) -> String? {
        resolveExecutableInSearchPath("codex", searchPath: searchPath)
    }

    func claudeTeamsHasExplicitTeammateMode(commandArgs: [String]) -> Bool {
        commandArgs.contains { arg in
            arg == "--teammate-mode" || arg.hasPrefix("--teammate-mode=")
        }
    }

    func claudeTeamsLaunchArguments(commandArgs: [String]) -> [String] {
        guard !claudeTeamsHasExplicitTeammateMode(commandArgs: commandArgs) else {
            return commandArgs
        }
        return ["--teammate-mode", "auto"] + commandArgs
    }

    private func providerExecutableSearchDirectories(searchPath: String?) -> [String] {
        var directories = searchPath?.split(separator: ":").map(String.init) ?? []
        let environment = ProcessInfo.processInfo.environment
        if let home = environment["HOME"], !home.isEmpty {
            directories.append(contentsOf: [
                "\(home)/.local/bin",
                "\(home)/.bun/bin",
                "\(home)/.nvm/current/bin",
                "\(home)/.volta/bin",
                "\(home)/.fnm/current/bin",
                "\(home)/.local/share/mise/shims",
                "\(home)/.asdf/shims",
                "\(home)/bin"
            ])
            directories.append(contentsOf: providerNodeVersionBinDirectories(root: "\(home)/.nvm/versions/node", suffix: "bin"))
            directories.append(contentsOf: providerNodeVersionBinDirectories(root: "\(home)/Library/Application Support/fnm/node-versions", suffix: "installation/bin"))
            directories.append(contentsOf: providerNodeVersionBinDirectories(root: "\(home)/.local/share/fnm/node-versions", suffix: "installation/bin"))
        }
        directories.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ])

        var seen: Set<String> = []
        return directories.compactMap { rawDirectory in
            let trimmed = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let standardized = URL(fileURLWithPath: trimmed, isDirectory: true)
                .standardizedFileURL
                .path
            guard seen.insert(standardized).inserted else { return nil }
            return standardized
        }
    }

    private func providerNodeVersionBinDirectories(root: String, suffix: String) -> [String] {
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let versionURLs = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return versionURLs
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted(by: providerNodeVersionURLSortPrecedes)
            .map { versionURL in
                suffix.split(separator: "/").reduce(versionURL) { partial, component in
                    partial.appendingPathComponent(String(component), isDirectory: true)
                }.path
            }
    }

    private func providerNodeVersionURLSortPrecedes(_ lhs: URL, _ rhs: URL) -> Bool {
        let comparison = lhs.lastPathComponent.compare(
            rhs.lastPathComponent,
            options: [.caseInsensitive, .numeric]
        )
        if comparison != .orderedSame {
            return comparison == .orderedDescending
        }
        return lhs.path > rhs.path
    }

    private func bundledProviderBinDirectory() -> String? {
        guard let executableURL = resolvedExecutableURL()?.standardizedFileURL else {
            return nil
        }
        let directory = executableURL.deletingLastPathComponent().standardizedFileURL.path
        guard directory.hasSuffix("/Contents/Resources/bin") || directory.hasSuffix("/Resources/bin") else {
            return nil
        }
        return directory
    }
}
