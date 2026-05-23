import Foundation

enum AgentSessionProviderID: String, CaseIterable, Codable, Hashable, Sendable {
    case codex
    case claude
    case opencode
    case pi
}

enum AgentSessionTransport: String, Codable, Hashable, Sendable {
    case stdioJSONRPC
    case stdioJSONLines
    case httpSSELoopback
}

enum AgentSessionUnixSocketSupport: String, Codable, Hashable, Sendable {
    case notApplicable
    case unsupported
    case supported
    case unknown
}

struct AgentSessionLaunchPlan: Equatable, Sendable {
    var executableName: String
    var arguments: [String]
}

struct AgentResolvedLaunchPlan: Equatable, Sendable {
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
}

enum AgentExecutableResolverError: Error, Equatable, LocalizedError, Sendable {
    case missingExecutable(
        providerID: AgentSessionProviderID,
        providerName: String,
        executableName: String,
        searchPaths: [String]
    )

    var errorDescription: String? {
        switch self {
        case .missingExecutable(_, let providerName, let executableName, _):
            let format = String(
                localized: "agentSession.error.missingExecutable",
                defaultValue: "Could not find %@ executable `%@`. Install %@ and make sure `%@` is available on PATH."
            )
            return String(
                format: format,
                locale: Locale.current,
                providerName,
                executableName,
                providerName,
                executableName
            )
        }
    }
}

struct AgentExecutableResolver: Sendable {
    var baseEnvironment: [String: String]

    init(baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.baseEnvironment = baseEnvironment
    }

    func resolveLaunchPlan(for provider: AgentSessionProvider) throws -> AgentResolvedLaunchPlan {
        let environment = Self.providerEnvironment(baseEnvironment: baseEnvironment)
        let searchPaths = Self.commandSearchDirectories(environment: environment)
        guard let executablePath = Self.resolvedExecutablePath(
            provider.launchPlan.executableName,
            searchPaths: searchPaths
        ) else {
            throw AgentExecutableResolverError.missingExecutable(
                providerID: provider.id,
                providerName: provider.displayName,
                executableName: provider.launchPlan.executableName,
                searchPaths: searchPaths
            )
        }
        return AgentResolvedLaunchPlan(
            executablePath: executablePath,
            arguments: provider.launchPlan.arguments,
            environment: environment
        )
    }

    static func providerEnvironment(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = baseEnvironment
        let paths = commandSearchDirectories(
            environment: environment,
            skipOwnBundleResourceBin: false
        )
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let merged = (paths + existing)
            .reduce(into: [String]()) { paths, candidate in
                guard !candidate.isEmpty, !paths.contains(candidate) else { return }
                paths.append(candidate)
            }
            .joined(separator: ":")
        environment["PATH"] = merged
        return environment
    }

    static func resolvedExecutablePath(
        _ executable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        resolvedExecutablePath(
            executable,
            searchPaths: commandSearchDirectories(environment: environment)
        )
    }

    private static func resolvedExecutablePath(
        _ executable: String,
        searchPaths: [String]
    ) -> String? {
        guard !executable.isEmpty else { return nil }
        let fileManager = FileManager.default
        if executable.contains("/") {
            let directory = (executable as NSString).deletingLastPathComponent
            guard !shouldSkipSearchDirectory(directory) else { return nil }
            return fileManager.isExecutableFile(atPath: executable) ? executable : nil
        }

        for directory in searchPaths where !shouldSkipSearchDirectory(directory) {
            let path = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executable)
                .path
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    static func commandSearchDirectories(
        environment: [String: String],
        skipOwnBundleResourceBin: Bool = true
    ) -> [String] {
        var paths: [String] = []
        var seen: Set<String> = []

        func append(_ path: String?) {
            guard let path else { return }
            for component in path.split(separator: ":").map(String.init) {
                let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !(skipOwnBundleResourceBin && shouldSkipSearchDirectory(trimmed)),
                      seen.insert(trimmed).inserted else {
                    continue
                }
                paths.append(trimmed)
            }
        }

        let home = environment["HOME"]?.isEmpty == false ? environment["HOME"]! : NSHomeDirectory()
        append(environment["PATH"])
        if let resourceBinPath = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            append(resourceBinPath)
        }
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
        return paths
    }

    private static func appendNodeVersionManagerPaths(home: String, append: (String?) -> Void) {
        let fileManager = FileManager.default

        append((home as NSString).appendingPathComponent(".nvm/current/bin"))
        let nvmVersions = (home as NSString).appendingPathComponent(".nvm/versions/node")
        for version in sortedNodeVersionDirectories(in: nvmVersions, fileManager: fileManager) {
            append((nvmVersions as NSString).appendingPathComponent("\(version)/bin"))
        }

        append((home as NSString).appendingPathComponent(".fnm/current/bin"))
        let fnmVersionRoots = [
            (home as NSString).appendingPathComponent(".fnm/node-versions"),
            (home as NSString).appendingPathComponent("Library/Application Support/fnm/node-versions"),
            (home as NSString).appendingPathComponent(".local/share/fnm/node-versions"),
        ]
        for fnmVersions in fnmVersionRoots {
            for version in sortedNodeVersionDirectories(in: fnmVersions, fileManager: fileManager) {
                append((fnmVersions as NSString).appendingPathComponent("\(version)/installation/bin"))
                append((fnmVersions as NSString).appendingPathComponent("\(version)/bin"))
            }
        }
    }

    private static func sortedNodeVersionDirectories(
        in directory: String,
        fileManager: FileManager
    ) -> [String] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return []
        }
        return names
            .filter { name in
                var isDirectory: ObjCBool = false
                let path = (directory as NSString).appendingPathComponent(name)
                return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .sorted { lhs, rhs in
                compareNodeVersionsDescending(lhs, rhs)
            }
    }

    private static func compareNodeVersionsDescending(_ lhs: String, _ rhs: String) -> Bool {
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

    private static func nodeVersionComponents(_ version: String) -> [Int] {
        let normalizedVersion = version.hasPrefix("v")
            ? String(version.dropFirst())
            : version
        return normalizedVersion
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }

    private static func shouldSkipSearchDirectory(_ path: String) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .path
        if let resourceBin = Bundle.main.resourceURL?
            .appendingPathComponent("bin", isDirectory: true)
            .standardizedFileURL
            .path,
            standardizedPath == resourceBin {
            return true
        }
        return false
    }
}

struct AgentSessionProvider: Identifiable, Equatable, Sendable {
    var id: AgentSessionProviderID
    var displayName: String
    var transport: AgentSessionTransport
    var unixSocketSupport: AgentSessionUnixSocketSupport
    var launchPlan: AgentSessionLaunchPlan

    static let all: [AgentSessionProvider] = AgentSessionProviderID.allCases.map(provider)

    static func provider(_ id: AgentSessionProviderID) -> AgentSessionProvider {
        switch id {
        case .codex:
            return AgentSessionProvider(
                id: id,
                displayName: String(localized: "agentSession.provider.codex", defaultValue: "Codex"),
                transport: .stdioJSONRPC,
                unixSocketSupport: .notApplicable,
                launchPlan: AgentSessionLaunchPlan(
                    executableName: "codex",
                    arguments: ["app-server", "--listen", "stdio://"]
                )
            )
        case .claude:
            return AgentSessionProvider(
                id: id,
                displayName: String(localized: "agentSession.provider.claude", defaultValue: "Claude Code"),
                transport: .stdioJSONLines,
                unixSocketSupport: .notApplicable,
                launchPlan: AgentSessionLaunchPlan(
                    executableName: "claude",
                    arguments: [
                        "--output-format", "stream-json",
                        "--input-format", "stream-json",
                        "--permission-prompt-tool", "stdio",
                        "--include-partial-messages",
                    ]
                )
            )
        case .opencode:
            return AgentSessionProvider(
                id: id,
                displayName: String(localized: "agentSession.provider.opencode", defaultValue: "OpenCode"),
                transport: .httpSSELoopback,
                unixSocketSupport: .unsupported,
                launchPlan: AgentSessionLaunchPlan(
                    executableName: "opencode",
                    arguments: [
                        "serve",
                        "--hostname", "127.0.0.1",
                        "--port", "0",
                    ]
                )
            )
        case .pi:
            return AgentSessionProvider(
                id: id,
                displayName: String(localized: "agentSession.provider.pi", defaultValue: "Pi"),
                transport: .stdioJSONLines,
                unixSocketSupport: .notApplicable,
                launchPlan: AgentSessionLaunchPlan(
                    executableName: "pi",
                    arguments: ["--mode", "rpc"]
                )
            )
        }
    }
}
