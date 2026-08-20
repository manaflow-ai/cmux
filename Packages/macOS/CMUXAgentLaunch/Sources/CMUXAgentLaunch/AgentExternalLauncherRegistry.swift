import Foundation

/// The set of user-declared external launchers, and the argv rewriting they imply.
///
/// The registry is a pure value: callers read `cmux.json` (see
/// ``load(configPaths:fileManager:sanitize:)``) and hand the bytes over, so detection and resume
/// rewriting stay testable without a filesystem. Declarations that cannot change a restore are
/// dropped at construction, and a later declaration replaces an earlier one with the same id, so a
/// project-local `cmux.json` can override the user-level file the same way vault agents do.
public struct AgentExternalLauncherRegistry: Equatable, Sendable {
    /// The usable declarations, in declaration order.
    public let launchers: [AgentExternalLauncher]

    /// A registry with no declarations. Restores behave exactly as they did before the feature.
    public static let empty = AgentExternalLauncherRegistry(launchers: [])

    /// Creates a registry, dropping unusable declarations and de-duplicating by id.
    ///
    /// - Parameter launchers: Declarations in reading order; a later entry replaces an earlier entry
    ///   with the same id.
    public init(launchers: [AgentExternalLauncher]) {
        var ordered: [AgentExternalLauncher] = []
        var indexesByID: [String: Int] = [:]
        for launcher in launchers where launcher.isUsable {
            if let index = indexesByID[launcher.id] {
                ordered[index] = launcher
            } else {
                indexesByID[launcher.id] = ordered.count
                ordered.append(launcher)
            }
        }
        self.launchers = ordered
    }

    /// Decodes `agents.launchers` from already comment-stripped `cmux.json` bytes.
    ///
    /// A malformed file yields an empty registry rather than an error: a config typo must never make
    /// restore fail, it may only leave the wrapper unrestored.
    ///
    /// - Parameter sanitizedConfigJSON: `cmux.json` contents with JSONC comments removed.
    /// - Returns: The declared launchers, or an empty registry.
    public static func decoding(sanitizedConfigJSON: Data) -> AgentExternalLauncherRegistry {
        guard !sanitizedConfigJSON.isEmpty,
              let file = try? JSONDecoder().decode(ConfigFile.self, from: sanitizedConfigJSON),
              let declared = file.agents?.launchers else {
            return .empty
        }
        return AgentExternalLauncherRegistry(launchers: declared)
    }

    /// Loads and merges `agents.launchers` from a list of config paths.
    ///
    /// - Parameters:
    ///   - configPaths: Config files in increasing precedence order (user level first, project last).
    ///   - fileManager: Filesystem used to read the files.
    ///   - sanitize: JSONC comment stripping applied before decoding.
    /// - Returns: The merged registry.
    public static func load(
        configPaths: [String],
        fileManager: FileManager = .default,
        sanitize: (Data) throws -> Data
    ) -> AgentExternalLauncherRegistry {
        var merged: [AgentExternalLauncher] = []
        for path in configPaths {
            guard let data = fileManager.contents(atPath: path), !data.isEmpty,
                  let sanitized = try? sanitize(data) else { continue }
            merged.append(contentsOf: decoding(sanitizedConfigJSON: sanitized).launchers)
        }
        return AgentExternalLauncherRegistry(launchers: merged)
    }

    /// The config files that can declare external launchers, in increasing precedence order.
    ///
    /// The user-level file comes first and the nearest project file last, matching how vault agents
    /// merge, so a repository can pin the wrapper its sessions are started with.
    ///
    /// - Parameters:
    ///   - homeDirectory: The user's home directory.
    ///   - workingDirectory: The directory a project config is searched upwards from.
    ///   - fileManager: Filesystem used to probe for the files.
    /// - Returns: Existing config paths, deduplicated.
    public static func configPaths(
        homeDirectory: String,
        workingDirectory: String?,
        fileManager: FileManager = .default
    ) -> [String] {
        var paths: [String] = []
        let home = (homeDirectory as NSString).standardizingPath
        paths.append(
            ((home as NSString).appendingPathComponent(".config/cmux") as NSString)
                .appendingPathComponent("cmux.json")
        )
        if let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty,
           let projectPath = projectConfigPath(startingAt: workingDirectory, fileManager: fileManager) {
            paths.append(projectPath)
        }
        var seen: Set<String> = []
        return paths.filter { path in
            guard fileManager.fileExists(atPath: path) else { return false }
            return seen.insert(path).inserted
        }
    }

    /// Loads external launcher declarations from the user-level and project config files.
    ///
    /// - Parameters:
    ///   - homeDirectory: The user's home directory.
    ///   - workingDirectory: The directory a project config is searched upwards from.
    ///   - fileManager: Filesystem used to read the files.
    ///   - sanitize: JSONC comment stripping applied before decoding.
    /// - Returns: The merged registry.
    public static func load(
        homeDirectory: String,
        workingDirectory: String?,
        fileManager: FileManager = .default,
        sanitize: (Data) throws -> Data
    ) -> AgentExternalLauncherRegistry {
        load(
            configPaths: configPaths(
                homeDirectory: homeDirectory,
                workingDirectory: workingDirectory,
                fileManager: fileManager
            ),
            fileManager: fileManager,
            sanitize: sanitize
        )
    }

    private static func projectConfigPath(
        startingAt path: String,
        fileManager: FileManager
    ) -> String? {
        var isDirectory: ObjCBool = false
        let start = fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            ? path
            : (path as NSString).deletingLastPathComponent
        var current = (start as NSString).standardizingPath
        while true {
            let candidates = [
                ((current as NSString).appendingPathComponent(".cmux") as NSString)
                    .appendingPathComponent("cmux.json"),
                (current as NSString).appendingPathComponent("cmux.json"),
            ]
            for candidate in candidates where fileManager.fileExists(atPath: candidate) {
                return candidate
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { return nil }
            current = parent
        }
    }

    /// The declaration recorded under `id`, when it is still declared.
    ///
    /// - Parameter id: The captured launcher id.
    /// - Returns: The declaration, or `nil` when the user removed or renamed it.
    public func launcher(id: String?) -> AgentExternalLauncher? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            return nil
        }
        return launchers.first { $0.id == id }
    }

    /// Detects the launcher that started an agent, given its ancestor processes' argv.
    ///
    /// - Parameters:
    ///   - ancestorArgvs: Argv of the agent's ancestors, nearest ancestor first.
    ///   - kind: The built-in agent kind being captured, for example `"claude"`.
    /// - Returns: The nearest matching declaration, or `nil` when the agent was launched directly.
    public func detectedLauncher(ancestorArgvs: [[String]], kind: String) -> AgentExternalLauncher? {
        for argv in ancestorArgvs {
            if let match = launchers.first(where: { $0.wraps(kind: kind) && $0.matches(argv: argv) }) {
                return match
            }
        }
        return nil
    }

    /// Detects the launcher that started an agent by walking its ancestor processes.
    ///
    /// Process lookup is injected so detection stays testable, and the walk is depth-bounded: a
    /// wrapper is the agent's launcher, not an arbitrary ancestor, and stopping early keeps a login
    /// shell or the terminal itself from being mistaken for one.
    ///
    /// - Parameters:
    ///   - agentPID: The agent process whose ancestors are inspected.
    ///   - kind: The built-in agent kind being captured.
    ///   - maximumAncestorDepth: How many ancestors to inspect before giving up.
    ///   - parentPID: Parent lookup; a value of `1` or less ends the walk.
    ///   - argv: Argv lookup for one process.
    /// - Returns: The nearest matching declaration, or `nil`.
    public func detectedLauncher(
        agentPID: Int32,
        kind: String,
        maximumAncestorDepth: Int = 8,
        parentPID: (Int32) -> Int32,
        argv: (Int32) -> [String]?
    ) -> AgentExternalLauncher? {
        guard !launchers.isEmpty, agentPID > 1, maximumAncestorDepth > 0 else { return nil }
        var ancestorArgvs: [[String]] = []
        var current = agentPID
        for _ in 0..<maximumAncestorDepth {
            let parent = parentPID(current)
            guard parent > 1 else { break }
            if let candidate = argv(parent), !candidate.isEmpty {
                ancestorArgvs.append(candidate)
            }
            current = parent
        }
        return detectedLauncher(ancestorArgvs: ancestorArgvs, kind: kind)
    }

    /// Re-supplies a captured external launcher around an agent's own resume argv.
    ///
    /// - Parameters:
    ///   - argv: The resume argv cmux built for the agent, including `argv[0]`.
    ///   - launcherID: The launcher id recorded on the launch capture.
    ///   - kind: The built-in agent kind being resumed.
    /// - Returns: The wrapped argv, or `argv` unchanged when no usable declaration applies.
    public func applyingResumePrefix(
        to argv: [String],
        launcherID: String?,
        kind: String
    ) -> [String] {
        guard !argv.isEmpty,
              let launcher = launcher(id: launcherID),
              launcher.wraps(kind: kind) else {
            return argv
        }
        let agentArguments = launcher.includesAgentExecutable ? argv : Array(argv.dropFirst())
        guard !agentArguments.isEmpty else { return argv }
        return launcher.resumeArgvPrefix + agentArguments
    }

    private struct ConfigFile: Decodable {
        let agents: AgentsSection?

        struct AgentsSection: Decodable {
            let launchers: [AgentExternalLauncher]?
        }
    }
}
