import Foundation

extension CMUXCLI {
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
        for entry in providerExecutableSearchDirectories(searchPath: searchPath) {
            let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
                .path
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if let skip, skip(candidate) { continue }
            return candidate
        }
        return nil
    }

    private func providerExecutableSearchDirectories(searchPath: String?) -> [String] {
        var entries: [String] = []
        var seen = Set<String>()

        func append(_ rawPath: String?) {
            guard let rawPath else { return }
            for rawEntry in rawPath.split(separator: ":").map(String.init) {
                let expanded = (rawEntry as NSString).expandingTildeInPath
                let standardized = (expanded as NSString).standardizingPath
                guard !standardized.isEmpty,
                      !seen.contains(standardized),
                      !shouldSkipProviderSearchDirectory(standardized) else { continue }
                seen.insert(standardized)
                entries.append(standardized)
            }
        }

        append(searchPath)

        return entries
    }

    private func shouldSkipProviderSearchDirectory(_ path: String) -> Bool {
        let standardized = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
        if let resourceBin = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .path {
            let standardizedResourceBin = ((resourceBin as NSString).expandingTildeInPath as NSString).standardizingPath
            if standardized == standardizedResourceBin {
                return true
            }
        }
        return false
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
}
