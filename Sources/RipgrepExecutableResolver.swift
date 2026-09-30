import Foundation

enum RipgrepIntegrationSettings {
    static let customRipgrepPathKey = "ripgrepCustomBinaryPath"

    static func rawCustomRipgrepPath(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: customRipgrepPathKey)
    }

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
}

struct FileSearchRipgrepExecutable: Equatable, Sendable {
    let url: URL
    let prefixArguments: [String]
}

enum RipgrepExecutableResolution: Equatable, Sendable {
    case found(FileSearchRipgrepExecutable)
    case configuredPathNotExecutable(String)
    case notFound
}

enum RipgrepExecutableResolver {
    static func resolve(
        configuredPath: String? = RipgrepIntegrationSettings.rawCustomRipgrepPath(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userName: String = NSUserName(),
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> FileSearchRipgrepExecutable? {
        guard case .found(let executable) = resolution(
            configuredPath: configuredPath,
            environment: environment,
            userName: userName,
            homeDirectory: homeDirectory,
            isExecutable: isExecutable
        ) else {
            return nil
        }
        return executable
    }

    static func resolution(
        configuredPath: String? = RipgrepIntegrationSettings.rawCustomRipgrepPath(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userName: String = NSUserName(),
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> RipgrepExecutableResolution {
        if let configuredPath = RipgrepIntegrationSettings.normalizedCustomPath(
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

    private static func defaultSearchPaths(userName: String, homeDirectory: String) -> [String] {
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

enum FileExplorerSearchMessages {
    static func configuredRipgrepPathNotExecutable(_ path: String) -> String {
        String(
            format: String(
                localized: "fileExplorer.search.rgConfiguredPathNotExecutable",
                defaultValue: "Configured ripgrep path is not executable: %@"
            ),
            path
        )
    }

    static func sshSearchFailed(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return String(
                localized: "fileSearch.error.sshFailed",
                defaultValue: "Could not search over SSH. Check the connection and try again."
            )
        }
        return String(
            format: String(
                localized: "fileSearch.error.sshFailedDetail",
                defaultValue: "Could not search over SSH: %@"
            ),
            trimmed
        )
    }
}
