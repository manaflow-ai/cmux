public import Foundation

/// Resolves the `rg` (ripgrep) executable to launch for file search.
///
/// Resolution order: a user-configured binary path (from settings) if it is
/// executable, then a fixed list of known install locations (Homebrew, MacPorts,
/// Nix profiles), then each directory on `PATH`. The dependencies that make this
/// observable (the configured path, the environment, the current user/home, and
/// the executability probe) are constructor-injected so the policy is testable
/// without touching the real filesystem or `UserDefaults`.
public struct RipgrepExecutableResolver {
    /// `UserDefaults` key holding the user-configured custom `rg` binary path.
    public static let customRipgrepPathKey = "ripgrepCustomBinaryPath"

    private let configuredPath: String?
    private let environment: [String: String]
    private let userName: String
    private let homeDirectory: String
    private let isExecutable: (String) -> Bool

    /// - Parameters:
    ///   - configuredPath: raw user-configured `rg` path (defaults to the value
    ///     stored under ``customRipgrepPathKey`` in `UserDefaults.standard`).
    ///   - environment: process environment used to read `PATH`.
    ///   - userName: current user name, used to build per-user Nix paths.
    ///   - homeDirectory: home directory, used to expand `~` and per-user paths.
    ///   - isExecutable: predicate testing whether a path is an executable file.
    public init(
        configuredPath: String? = RipgrepExecutableResolver.rawCustomRipgrepPath(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userName: String = NSUserName(),
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.configuredPath = configuredPath
        self.environment = environment
        self.userName = userName
        self.homeDirectory = homeDirectory
        self.isExecutable = isExecutable
    }

    /// The resolved executable, or nil for any non-`found` outcome.
    public func resolve() -> FileSearchRipgrepExecutable? {
        guard case .found(let executable) = resolution() else {
            return nil
        }
        return executable
    }

    /// Full resolution outcome, distinguishing a configured-but-not-executable
    /// path from a plain not-found.
    public func resolution() -> RipgrepExecutableResolution {
        if let configuredPath = Self.normalizedCustomPath(
            configuredPath,
            homeDirectory: homeDirectory
        ) {
            if isExecutable(configuredPath) {
                return .found(FileSearchRipgrepExecutable(url: URL(fileURLWithPath: configuredPath), prefixArguments: []))
            }
            return .configuredPathNotExecutable(configuredPath)
        }

        for path in defaultSearchPaths(userName: userName, homeDirectory: homeDirectory) where isExecutable(path) {
            return .found(FileSearchRipgrepExecutable(url: URL(fileURLWithPath: path), prefixArguments: []))
        }

        let pathValue = environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent("rg").path
            if isExecutable(path) {
                return .found(FileSearchRipgrepExecutable(url: URL(fileURLWithPath: path), prefixArguments: []))
            }
        }
        return .notFound
    }

    /// Raw user-configured custom `rg` path from `UserDefaults`, before
    /// normalization. nil when unset.
    public static func rawCustomRipgrepPath(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: customRipgrepPathKey)
    }

    /// Normalizes a raw configured path: trims whitespace, treats empty as nil,
    /// and expands a leading `~`/`~/` against `homeDirectory`.
    static func normalizedCustomPath(_ rawPath: String?, homeDirectory: String = NSHomeDirectory()) -> String? {
        let trimmed = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }

        if trimmed == "~" {
            return (homeDirectory as NSString).standardizingPath
        }
        if trimmed.hasPrefix("~/") {
            let home = (homeDirectory as NSString).standardizingPath
            let relativePath = String(trimmed.dropFirst(2))
            return (home as NSString).appendingPathComponent(relativePath)
        }
        return trimmed
    }

    private func defaultSearchPaths(userName: String, homeDirectory: String) -> [String] {
        let homeDirectory = (homeDirectory as NSString).standardizingPath
        return [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/opt/local/bin/rg",
            "/usr/bin/rg",
            "/etc/profiles/per-user/\(userName)/bin/rg",
            "/run/current-system/sw/bin/rg",
            "/nix/var/nix/profiles/default/bin/rg",
            "\(homeDirectory)/.nix-profile/bin/rg",
            "/nix/var/nix/profiles/per-user/\(userName)/profile/bin/rg",
        ]
    }
}
