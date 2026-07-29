import Foundation

/// Describes one OMP sessions root and how transcripts are organized beneath it.
public struct OmpSessionRoot: Sendable, Equatable {
    /// The named OMP profile, or `nil` for the default profile.
    public let profile: String?
    /// The absolute sessions-root path.
    public let path: String
    /// Whether callers must append an OMP cwd bucket before scanning transcripts.
    public let usesCwdBuckets: Bool

    /// Creates an OMP sessions-root descriptor.
    /// - Parameters:
    ///   - profile: The named profile, or `nil` for the default profile.
    ///   - path: The absolute sessions-root path.
    ///   - usesCwdBuckets: Whether transcripts live in cwd buckets beneath `path`.
    public init(profile: String?, path: String, usesCwdBuckets: Bool) {
        self.profile = profile
        self.path = path
        self.usesCwdBuckets = usesCwdBuckets
    }
}

/// Holds current and legacy OMP cwd bucket names for one working directory.
public struct OmpCwdBucketNames: Sendable, Equatable {
    /// The bucket name emitted by current OMP releases.
    public let current: String
    /// The earlier absolute-path bucket name.
    public let legacy: String

    /// Creates a pair of current and legacy bucket names.
    /// - Parameters:
    ///   - current: The current bucket name.
    ///   - legacy: The legacy bucket name.
    public init(current: String, legacy: String) {
        self.current = current
        self.legacy = legacy
    }

    /// The deduplicated consumer lookup order, current first.
    public var searchOrder: [String] { current == legacy ? [current] : [current, legacy] }
}

/// Contains OMP's resolved profile and directory paths for one launch.
public struct OmpDirectoryResolution: Sendable, Equatable {
    /// The selected named profile, or `nil` for the default profile.
    public let profile: String?
    /// The selected profile's configuration directory.
    public let configDirectory: String
    /// The selected profile's agent directory.
    public let agentDirectory: String
    /// The effective sessions directory after explicit and XDG precedence.
    public let sessionsDirectory: String
    /// The effective OMP process cwd after startup cwd handling.
    public let currentDirectory: String
    /// Whether transcripts live in cwd buckets beneath ``sessionsDirectory``.
    public let usesCwdBuckets: Bool

    /// Creates a resolved OMP directory set.
    /// - Parameters:
    ///   - profile: The selected profile, or `nil` for the default profile.
    ///   - configDirectory: The selected profile's configuration directory.
    ///   - agentDirectory: The selected profile's agent directory.
    ///   - sessionsDirectory: The effective sessions directory.
    ///   - currentDirectory: The effective OMP process cwd.
    ///   - usesCwdBuckets: Whether transcripts live in cwd buckets.
    public init(
        profile: String?,
        configDirectory: String,
        agentDirectory: String,
        sessionsDirectory: String,
        currentDirectory: String,
        usesCwdBuckets: Bool
    ) {
        self.profile = profile
        self.configDirectory = configDirectory
        self.agentDirectory = agentDirectory
        self.sessionsDirectory = sessionsDirectory
        self.currentDirectory = currentDirectory
        self.usesCwdBuckets = usesCwdBuckets
    }

    /// The effective sessions directory as a consumer-facing descriptor.
    public var sessionRoot: OmpSessionRoot {
        OmpSessionRoot(profile: profile, path: sessionsDirectory, usesCwdBuckets: usesCwdBuckets)
    }
}

/// Errors produced while validating OMP launch selectors.
public enum OmpDirectoryResolverError: Error, Sendable, Equatable {
    /// An explicit selector was present without a usable value.
    case missingOptionValue(String)
    /// A profile name did not satisfy OMP's portable profile-name contract.
    case invalidProfileName(String)
}

/// Resolves OMP profile, configuration, agent, session, and cwd-bucket paths.
public struct OmpDirectoryResolver: Sendable, Equatable {
    /// Creates a stateless OMP directory resolver.
    public init() {}

    /// Resolves OMP directories with the process-default filesystem.
    /// - Parameters:
    ///   - arguments: Captured OMP argv, including the executable when available.
    ///   - environment: The captured launch environment.
    ///   - homeDirectory: The launch user's home directory.
    ///   - currentDirectory: The launch cwd used for relative overrides.
    /// - Returns: The effective profile and directory paths.
    /// - Throws: ``OmpDirectoryResolverError`` for malformed selectors or profiles.
    public func resolve(
        arguments: [String],
        environment: [String: String],
        homeDirectory: String,
        currentDirectory: String
    ) throws -> OmpDirectoryResolution {
        try resolve(
            arguments: arguments,
            environment: environment,
            homeDirectory: homeDirectory,
            currentDirectory: currentDirectory,
            fileManager: .default
        )
    }

    /// Resolves OMP directories with an injected filesystem.
    /// - Parameters:
    ///   - arguments: Captured OMP argv, including the executable when available.
    ///   - environment: The captured launch environment.
    ///   - homeDirectory: The launch user's home directory.
    ///   - currentDirectory: The launch cwd used for relative overrides.
    ///   - fileManager: The filesystem used for XDG existence checks.
    /// - Returns: The effective profile and directory paths.
    /// - Throws: ``OmpDirectoryResolverError`` for malformed selectors or profiles.
    public func resolve(
        arguments: [String],
        environment: [String: String],
        homeDirectory: String,
        currentDirectory: String,
        fileManager: FileManager
    ) throws -> OmpDirectoryResolution {
        let launchOptions = try launchOptions(arguments: arguments)
        let profile = try selectedProfile(
            explicit: launchOptions.profile,
            environment: environment
        )
        let configRoot = configRoot(environment: environment, homeDirectory: homeDirectory)
        let profileRoot = profile.map {
            configRoot.appendingPathComponent("profiles/\($0)", isDirectory: true)
        } ?? configRoot
        let agent = agentDirectory(
            profile: profile,
            environment: environment,
            configRoot: configRoot,
            currentDirectory: currentDirectory
        )
        let startupDirectory = startupDirectory(
            explicit: launchOptions.currentDirectory,
            allowsHome: launchOptions.allowsHome,
            launchDirectory: currentDirectory,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )

        if let explicit = launchOptions.sessionDirectory, !explicit.isEmpty {
            return OmpDirectoryResolution(
                profile: profile,
                configDirectory: profileRoot.path,
                agentDirectory: agent.url.path,
                sessionsDirectory: resolvedPath(explicit, relativeTo: startupDirectory.path).path,
                currentDirectory: startupDirectory.path,
                usesCwdBuckets: false
            )
        }

        let sessions = xdgSessionsDirectory(
            profile: profile,
            environment: environment,
            currentDirectory: currentDirectory,
            fileManager: fileManager,
            customDefaultAgentDirectory: agent.isCustomDefault
        ) ?? agent.url.appendingPathComponent("sessions", isDirectory: true)
        return OmpDirectoryResolution(
            profile: profile,
            configDirectory: profileRoot.path,
            agentDirectory: agent.url.path,
            sessionsDirectory: sessions.path,
            currentDirectory: startupDirectory.path,
            usesCwdBuckets: true
        )
    }

    /// Enumerates current and legacy default and valid named-profile session roots.
    /// - Parameters:
    ///   - environment: The captured launch environment.
    ///   - homeDirectory: The launch user's home directory.
    ///   - currentDirectory: The launch cwd used for relative custom roots.
    ///   - fileManager: The filesystem used for enumeration and existence checks.
    /// - Returns: Current roots first, followed by distinct legacy roots in stable order.
    public func sessionRoots(
        environment: [String: String],
        homeDirectory: String,
        currentDirectory: String,
        fileManager: FileManager
    ) -> [OmpSessionRoot] {
        let root = configRoot(environment: environment, homeDirectory: homeDirectory)
        let agent = agentDirectory(
            profile: nil,
            environment: environment,
            configRoot: root,
            currentDirectory: currentDirectory
        )
        let defaultSessions = xdgSessionsDirectory(
            profile: nil,
            environment: environment,
            currentDirectory: currentDirectory,
            fileManager: fileManager,
            customDefaultAgentDirectory: agent.isCustomDefault
        ) ?? agent.url.appendingPathComponent("sessions", isDirectory: true)
        let agentSessions = agent.url.appendingPathComponent("sessions", isDirectory: true)
        var results = [OmpSessionRoot(profile: nil, path: defaultSessions.path, usesCwdBuckets: true)]
        if defaultSessions.standardizedFileURL.path != agentSessions.standardizedFileURL.path,
           fileManager.fileExists(atPath: agentSessions.path) {
            results.append(OmpSessionRoot(
                profile: nil,
                path: agentSessions.path,
                usesCwdBuckets: true
            ))
        }

        let configProfiles = root.appendingPathComponent("profiles", isDirectory: true)
        let configNames = directoryProfileNames(at: configProfiles, fileManager: fileManager)
        let xdgRoot = xdgOmpRoot(
            environment: environment,
            currentDirectory: currentDirectory,
            fileManager: fileManager
        )
        let xdgNames = xdgRoot.map {
            directoryProfileNames(
                at: $0.appendingPathComponent("profiles", isDirectory: true),
                fileManager: fileManager
            )
        } ?? []
        for profile in configNames.union(xdgNames).sorted() {
            if xdgNames.contains(profile), let xdgRoot {
                results.append(OmpSessionRoot(
                    profile: profile,
                    path: xdgRoot
                        .appendingPathComponent("profiles/\(profile)/sessions", isDirectory: true)
                        .path,
                    usesCwdBuckets: true
                ))
            }
            if configNames.contains(profile) {
                results.append(OmpSessionRoot(
                    profile: profile,
                    path: root
                        .appendingPathComponent(
                            "profiles/\(profile)/agent/sessions",
                            isDirectory: true
                        )
                        .path,
                    usesCwdBuckets: true
                ))
            }
        }

        var seen: Set<String> = []
        return results.filter { descriptor in
            let url = URL(fileURLWithPath: descriptor.path, isDirectory: true)
            let comparable = fileManager.fileExists(atPath: descriptor.path)
                ? url.resolvingSymlinksInPath().standardizedFileURL.path
                : url.standardizedFileURL.path
            return seen.insert(comparable).inserted
        }
    }

    /// Computes current and legacy OMP cwd bucket names.
    /// - Parameters:
    ///   - currentDirectory: The working directory to encode.
    ///   - homeDirectory: The launch user's home directory.
    ///   - fileManager: The filesystem and temporary-directory provider.
    /// - Returns: Current and legacy bucket names.
    public func cwdBucketNames(
        currentDirectory: String,
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> OmpCwdBucketNames {
        let standardized = resolvedPath(currentDirectory, relativeTo: fileManager.currentDirectoryPath)
        let current = canonicalPathIfExisting(standardized, fileManager: fileManager)
        let home = canonicalPathIfExisting(
            resolvedPath(homeDirectory, relativeTo: fileManager.currentDirectoryPath),
            fileManager: fileManager
        )
        let temporary = canonicalPathIfExisting(fileManager.temporaryDirectory, fileManager: fileManager)
        let currentName: String
        if let relative = relativePath(current.path, beneath: home.path) {
            currentName = relative.isEmpty ? "-" : "-\(sanitize(relative))"
        } else if let relative = relativePath(current.path, beneath: temporary.path) {
            currentName = relative.isEmpty ? "-tmp" : "-tmp-\(sanitize(relative))"
        } else {
            currentName = legacyBucketName(current.path)
        }
        return OmpCwdBucketNames(
            current: currentName,
            legacy: legacyBucketName(standardized.path)
        )
    }
    private func selectedProfile(
        explicit: String?,
        environment: [String: String]
    ) throws -> String? {
        if let explicit {
            return try normalizedProfile(explicit, explicit: true)
        }
        if let ompProfile = environment["OMP_PROFILE"] {
            return try normalizedProfile(ompProfile, explicit: false)
        }
        if let piProfile = environment["PI_PROFILE"] {
            return try normalizedProfile(piProfile, explicit: false)
        }
        return nil
    }

    private func normalizedProfile(_ rawValue: String, explicit: Bool) throws -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            if explicit {
                throw OmpDirectoryResolverError.missingOptionValue("--profile")
            }
            return nil
        }
        if value == "default" { return nil }
        guard isValidNamedProfile(value) else {
            throw OmpDirectoryResolverError.invalidProfileName(value)
        }
        return value
    }

    private func isValidNamedProfile(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= 64,
              value != ".",
              value != "..",
              !value.hasSuffix(".")
        else {
            return false
        }
        guard value.unicodeScalars.allSatisfy({ scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 122)
                || scalar.value == 46
                || scalar.value == 95
                || scalar.value == 45
        }) else {
            return false
        }
        guard let first = value.unicodeScalars.first,
              (first.value >= 48 && first.value <= 57)
                || (first.value >= 97 && first.value <= 122)
        else {
            return false
        }

        let stem = value
            .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .lowercased()
        if ["con", "prn", "aux", "nul"].contains(stem) {
            return false
        }
        if stem.count == 4,
           (stem.hasPrefix("com") || stem.hasPrefix("lpt")),
           stem.last?.isNumber == true {
            return false
        }
        return true
    }

    private struct ProfileBootstrapResult {
        var arguments: [String]
        var profile: String?
    }

    private struct LaunchOptions {
        var profile: String?
        var sessionDirectory: String?
        var currentDirectory: String?
        var allowsHome = false
    }

    private static let profileBoundaryArgument = "--omp-profile-boundary"
    private static let launchSubcommands: Set<String> = ["launch", "acp"]
    private static let subcommands: Set<String> = [
        "launch", "acp", "auth-broker", "auth-gateway", "agents", "bench",
        "cleanse", "commit", "completions", "__complete", "config",
        "dry-balance", "gc", "grep", "gallery", "grievances", "install",
        "join", "models", "plugin", "say", "setup", "shell", "read", "ssh",
        "stats", "update", "usage", "tiny-models", "token", "ttsr", "worktree",
        "wt", "search", "q",
    ]
    private static let stringValueOptions: Set<String> = [
        "--cwd", "--config", "--add-dir", "--mode", "--fork", "--provider",
        "--model", "--smol", "--slow", "--plan", "--prewalk-into",
        "--plan-yolo-into", "--max-time", "--api-key", "--system-prompt",
        "--append-system-prompt", "--provider-session-id", "--prompt-cache-key",
        "--session-dir", "--models", "--tools", "--thinking", "--export",
        "--hook", "--extension", "-e", "--plugin-dir", "--skills",
        "--approval-mode",
    ]
    private static let optionalValueOptions: Set<String> = [
        "--resume", "-r", "--session",
    ]
    private static let extensionShadowableStringOptions: Set<String> = ["--plan"]
    private static let valuelessLongOptions: Set<String> = [
        "--help", "--version", "--allow-home", "--continue", "--no-session",
        "--no-tools", "--no-lsp", "--no-pty", "--hide-thinking", "--advisor",
        "--prewalk", "--no-prewalk", "--plan-yolo", "--print",
        "--print-thoughts", "--no-extensions", "--no-skills", "--no-rules",
        "--no-title", "--auto-approve", "--yolo",
    ]

    private func launchOptions(arguments: [String]) throws -> LaunchOptions {
        let bootstrap = try extractProfileFlags(from: Array(arguments.dropFirst()))
        guard let arguments = launchArguments(from: bootstrap.arguments) else {
            return LaunchOptions(profile: bootstrap.profile)
        }

        var options = LaunchOptions(profile: bootstrap.profile)
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == Self.profileBoundaryArgument {
                index += 1
                continue
            }
            if argument == "--" {
                break
            }

            if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
                let option = String(argument[..<equals])
                let value = String(argument[argument.index(after: equals)...])
                if option == "--session-dir" {
                    options.sessionDirectory = value
                } else if option == "--cwd" {
                    options.currentDirectory = value
                } else if option == "--allow-home" {
                    options.allowsHome = true
                }
                index += 1
                continue
            }

            if Self.stringValueOptions.contains(argument) {
                let valueIndex = index + 1
                guard valueIndex < arguments.count,
                      arguments[valueIndex] != Self.profileBoundaryArgument
                else {
                    index += 1
                    continue
                }
                if argument == "--session-dir" {
                    options.sessionDirectory = arguments[valueIndex]
                } else if argument == "--cwd" {
                    options.currentDirectory = arguments[valueIndex]
                }
                index += 2
                continue
            }
            if Self.optionalValueOptions.contains(argument),
               let next = nextArgument(in: arguments, after: index),
               !next.isEmpty,
               !next.hasPrefix("-") {
                index += 2
                continue
            }
            if argument == "--allow-home" {
                options.allowsHome = true
            }
            index += 1
        }
        return options
    }

    private func extractProfileFlags(from arguments: [String]) throws -> ProfileBootstrapResult {
        var stripped: [String] = []
        var profile: String?
        var passThrough = false
        var sawSubcommand = false
        var canDispatchSubcommand = true
        var insertBoundaryBeforeNextValue = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if passThrough || sawSubcommand {
                stripped.append(argument)
                index += 1
                continue
            }
            if insertBoundaryBeforeNextValue {
                if !argument.hasPrefix("-") {
                    stripped.append(Self.profileBoundaryArgument)
                }
                insertBoundaryBeforeNextValue = false
            }
            if argument == "--" {
                passThrough = true
                stripped.append(argument)
                index += 1
                continue
            }
            if argument == "--profile" {
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw OmpDirectoryResolverError.missingOptionValue("--profile")
                }
                let value = arguments[valueIndex]
                guard !value.isEmpty, !value.hasPrefix("-") else {
                    throw OmpDirectoryResolverError.missingOptionValue("--profile")
                }
                profile = value
                insertBoundaryBeforeNextValue = needsProfileBoundary(after: stripped)
                index += 2
                continue
            }
            if argument.hasPrefix("--profile=") {
                let value = String(argument.dropFirst("--profile=".count))
                guard !value.isEmpty else {
                    throw OmpDirectoryResolverError.missingOptionValue("--profile")
                }
                profile = value
                insertBoundaryBeforeNextValue = needsProfileBoundary(after: stripped)
                index += 1
                continue
            }
            if argument == "--alias" {
                let valueIndex = index + 1
                guard valueIndex < arguments.count else {
                    throw OmpDirectoryResolverError.missingOptionValue("--alias")
                }
                let value = arguments[valueIndex]
                guard !value.isEmpty, !value.hasPrefix("-") else {
                    throw OmpDirectoryResolverError.missingOptionValue("--alias")
                }
                insertBoundaryBeforeNextValue = needsProfileBoundary(after: stripped)
                index += 2
                continue
            }
            if argument.hasPrefix("--alias=") {
                let value = String(argument.dropFirst("--alias=".count))
                guard !value.isEmpty else {
                    throw OmpDirectoryResolverError.missingOptionValue("--alias")
                }
                insertBoundaryBeforeNextValue = needsProfileBoundary(after: stripped)
                index += 1
                continue
            }
            if Self.extensionShadowableStringOptions.contains(argument) {
                canDispatchSubcommand = false
                stripped.append(argument)
                if let next = nextArgument(in: arguments, after: index), !next.hasPrefix("-") {
                    stripped.append(next)
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if Self.stringValueOptions.contains(argument) {
                canDispatchSubcommand = false
                stripped.append(argument)
                if let next = nextArgument(in: arguments, after: index) {
                    stripped.append(next)
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if Self.optionalValueOptions.contains(argument) {
                canDispatchSubcommand = false
                stripped.append(argument)
                if let next = nextArgument(in: arguments, after: index),
                   !next.isEmpty,
                   !next.hasPrefix("-") {
                    stripped.append(next)
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if isUnknownLongValueCandidate(argument) {
                canDispatchSubcommand = false
                stripped.append(argument)
                if let next = nextArgument(in: arguments, after: index), !next.hasPrefix("-") {
                    stripped.append(next)
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            if canDispatchSubcommand,
               Self.subcommands.contains(argument),
               !Self.launchSubcommands.contains(argument) {
                sawSubcommand = true
            }
            canDispatchSubcommand = false
            stripped.append(argument)
            index += 1
        }
        return ProfileBootstrapResult(arguments: stripped, profile: profile)
    }

    private func nextArgument(in arguments: [String], after index: Int) -> String? {
        let nextIndex = index + 1
        return nextIndex < arguments.count ? arguments[nextIndex] : nil
    }

    private func launchArguments(from arguments: [String]) -> [String]? {
        guard let first = arguments.first else { return [] }
        if ["--help", "-h", "--version", "-v", "help"].contains(first) {
            return nil
        }
        if Self.subcommands.contains(first) {
            guard Self.launchSubcommands.contains(first) else { return nil }
            return Array(arguments.dropFirst())
        }

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return arguments }
            if !argument.hasPrefix("-") {
                guard Self.subcommands.contains(argument) else { return arguments }
                guard Self.launchSubcommands.contains(argument) else { return nil }
                var launchArguments = arguments
                launchArguments.remove(at: index)
                return launchArguments
            }
            if flagConsumesValue(argument, next: nextArgument(in: arguments, after: index)) {
                index += 2
            } else {
                index += 1
            }
        }
        return arguments
    }

    private func needsProfileBoundary(after stripped: [String]) -> Bool {
        guard let previous = stripped.last else { return false }
        return Self.optionalValueOptions.contains(previous)
            || Self.extensionShadowableStringOptions.contains(previous)
            || isUnknownLongValueCandidate(previous)
    }

    private func flagConsumesValue(_ option: String, next: String?) -> Bool {
        if option.hasPrefix("--"), option.contains("=") { return false }
        guard let next else { return false }
        if Self.stringValueOptions.contains(option) { return true }
        let valueLike = !next.hasPrefix("-")
        if Self.optionalValueOptions.contains(option) {
            return valueLike && !next.isEmpty
        }
        if isUnknownLongValueCandidate(option) {
            return valueLike
        }
        return false
    }

    private func isUnknownLongValueCandidate(_ argument: String) -> Bool {
        argument.hasPrefix("--")
            && !argument.contains("=")
            && !Self.stringValueOptions.contains(argument)
            && !Self.optionalValueOptions.contains(argument)
            && !Self.valuelessLongOptions.contains(argument)
    }

    private func startupDirectory(
        explicit: String?,
        allowsHome: Bool,
        launchDirectory: String,
        homeDirectory: String,
        fileManager: FileManager
    ) -> URL {
        let launch = resolvedPath(launchDirectory, relativeTo: fileManager.currentDirectoryPath)
        if let explicit, !explicit.isEmpty {
            return resolvedPath(explicit, relativeTo: launch.path)
        }
        guard !allowsHome else { return launch }

        let home = resolvedPath(homeDirectory, relativeTo: fileManager.currentDirectoryPath)
        let comparableLaunch = canonicalPathIfExisting(launch, fileManager: fileManager)
        let comparableHome = canonicalPathIfExisting(home, fileManager: fileManager)
        guard comparableLaunch.path == comparableHome.path else { return launch }

        let candidates = [
            home.appendingPathComponent("tmp", isDirectory: true),
            URL(fileURLWithPath: "/tmp", isDirectory: true),
            URL(fileURLWithPath: "/var/tmp", isDirectory: true),
            fileManager.temporaryDirectory,
        ]
        return candidates.first(where: { isDirectory($0, fileManager: fileManager) }) ?? launch
    }

    private func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func configRoot(environment: [String: String], homeDirectory: String) -> URL {
        let home = URL(fileURLWithPath: homeDirectory, isDirectory: true).standardizedFileURL
        let configured = environment["PI_CONFIG_DIR"]
        let component = configured.flatMap { $0.isEmpty ? nil : $0 } ?? ".omp"
        let homeJoinedComponent = component.drop(while: { $0 == "/" })
        return home
            .appendingPathComponent(String(homeJoinedComponent), isDirectory: true)
            .standardizedFileURL
    }

    private func agentDirectory(
        profile: String?,
        environment: [String: String],
        configRoot: URL,
        currentDirectory: String
    ) -> (url: URL, isCustomDefault: Bool) {
        if let profile {
            return (
                configRoot.appendingPathComponent(
                    "profiles/\(profile)/agent",
                    isDirectory: true
                ),
                false
            )
        }

        let defaultAgent = configRoot
            .appendingPathComponent("agent", isDirectory: true)
            .standardizedFileURL
        if let rawAgentDirectory = nonEmpty(environment["PI_CODING_AGENT_DIR"]),
           !isInheritedProfileAgentDirectory(
               rawAgentDirectory,
               environment: environment,
               configRoot: configRoot
           ) {
            let candidate = resolvedPath(rawAgentDirectory, relativeTo: currentDirectory)
            return (candidate, candidate.path != defaultAgent.path)
        }
        return (defaultAgent, false)
    }

    private func isInheritedProfileAgentDirectory(
        _ rawAgentDirectory: String,
        environment: [String: String],
        configRoot: URL
    ) -> Bool {
        let environmentProfile: String? = {
            if let ompProfile = environment["OMP_PROFILE"] {
                return validNamedProfileOrNil(ompProfile)
            }
            return environment["PI_PROFILE"].flatMap(validNamedProfileOrNil)
        }()
        let sourceProfile =
            environmentProfile
            ?? environment["PI_PROFILE"].flatMap(validNamedProfileOrNil)
        guard let sourceProfile else { return false }
        let derived = configRoot
            .appendingPathComponent("profiles/\(sourceProfile)/agent", isDirectory: true)
            .standardizedFileURL
        return rawAgentDirectory == derived.path
    }

    private func validNamedProfileOrNil(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != "default", isValidNamedProfile(value) else { return nil }
        return value
    }

    private func xdgSessionsDirectory(
        profile: String?,
        environment: [String: String],
        currentDirectory: String,
        fileManager: FileManager,
        customDefaultAgentDirectory: Bool
    ) -> URL? {
        guard !customDefaultAgentDirectory,
              let xdgRoot = xdgOmpRoot(
                  environment: environment,
                  currentDirectory: currentDirectory,
                  fileManager: fileManager
              )
        else {
            return nil
        }
        let appRoot = profile.map {
            xdgRoot.appendingPathComponent("profiles/\($0)", isDirectory: true)
        } ?? xdgRoot
        guard fileManager.fileExists(atPath: appRoot.path) else { return nil }
        return appRoot.appendingPathComponent("sessions", isDirectory: true)
    }

    private func xdgOmpRoot(
        environment: [String: String],
        currentDirectory: String,
        fileManager: FileManager
    ) -> URL? {
        guard let rawXdgHome = nonEmpty(environment["XDG_DATA_HOME"]) else { return nil }
        let root = resolvedPath(rawXdgHome, relativeTo: currentDirectory)
            .appendingPathComponent("omp", isDirectory: true)
        return fileManager.fileExists(atPath: root.path) ? root : nil
    }

    private func directoryProfileNames(
        at directory: URL,
        fileManager: FileManager
    ) -> Set<String> {
        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return Set(children.compactMap { child in
            let name = child.lastPathComponent
            guard name != "default", isValidNamedProfile(name) else { return nil }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true ? name : nil
        })
    }

    private func resolvedPath(_ path: String, relativeTo currentDirectory: String) -> URL {
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        return URL(fileURLWithPath: currentDirectory, isDirectory: true)
            .appendingPathComponent(path, isDirectory: true)
            .standardizedFileURL
    }

    private func canonicalPathIfExisting(_ url: URL, fileManager: FileManager) -> URL {
        guard fileManager.fileExists(atPath: url.path) else {
            return url.standardizedFileURL
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func relativePath(_ path: String, beneath root: String) -> String? {
        if path == root { return "" }
        let prefix = root == "/" ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private func legacyBucketName(_ path: String) -> String {
        let withoutLeadingSlash = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return "--\(sanitize(withoutLeadingSlash))--"
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
