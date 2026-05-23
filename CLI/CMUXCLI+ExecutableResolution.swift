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

    func providerExecutableLaunchPath(searchPath: String?) -> String {
        providerExecutableSearchDirectories(searchPath: searchPath).joined(separator: ":")
    }

    private func providerExecutableSearchDirectories(
        searchPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
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
        let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? environment["HOME"]!
            : NSHomeDirectory()
        append((home as NSString).appendingPathComponent(".bun/bin"))
        append((home as NSString).appendingPathComponent(".local/bin"))
        append((home as NSString).appendingPathComponent("bin"))
        append((home as NSString).appendingPathComponent(".volta/bin"))
        append((home as NSString).appendingPathComponent(".asdf/shims"))
        append((home as NSString).appendingPathComponent(".deno/bin"))
        append((home as NSString).appendingPathComponent("Library/pnpm"))
        append((home as NSString).appendingPathComponent(".local/share/mise/shims"))
        appendNodeVersionManagerPaths(home: home, append: append)
        append("/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/opt/local/bin")
        append("/usr/bin:/bin:/usr/sbin:/sbin")

        return entries
    }

    private func appendNodeVersionManagerPaths(home: String, append: (String?) -> Void) {
        append((home as NSString).appendingPathComponent(".nvm/current/bin"))

        let nvmVersions = (home as NSString).appendingPathComponent(".nvm/versions/node")
        for version in sortedNodeVersionDirectories(in: nvmVersions) {
            append((nvmVersions as NSString).appendingPathComponent("\(version)/bin"))
        }

        append((home as NSString).appendingPathComponent(".fnm/current/bin"))
        let fnmVersionRoots = [
            (home as NSString).appendingPathComponent(".fnm/node-versions"),
            (home as NSString).appendingPathComponent("Library/Application Support/fnm/node-versions"),
            (home as NSString).appendingPathComponent(".local/share/fnm/node-versions"),
        ]
        for fnmVersions in fnmVersionRoots {
            for version in sortedNodeVersionDirectories(in: fnmVersions) {
                append((fnmVersions as NSString).appendingPathComponent("\(version)/installation/bin"))
                append((fnmVersions as NSString).appendingPathComponent("\(version)/bin"))
            }
        }
    }

    private func sortedNodeVersionDirectories(in directory: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        return names
            .filter { name in
                var isDirectory: ObjCBool = false
                let path = (directory as NSString).appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .sorted { lhs, rhs in
                compareNodeVersionsDescending(lhs, rhs)
            }
    }

    private func compareNodeVersionsDescending(_ lhs: String, _ rhs: String) -> Bool {
        let lhsComponents = nodeVersionComponents(lhs)
        let rhsComponents = nodeVersionComponents(rhs)
        for index in 0..<max(lhsComponents.count, rhsComponents.count) {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : 0
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : 0
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
        }
        return lhs > rhs
    }

    private func nodeVersionComponents(_ version: String) -> [Int] {
        let normalizedVersion = version.hasPrefix("v")
            ? String(version.dropFirst())
            : version
        return normalizedVersion
            .split(separator: ".")
            .map { Int($0) ?? 0 }
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
