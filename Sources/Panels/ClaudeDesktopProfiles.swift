import Foundation

/// A Claude Desktop profile (account) as a future account switcher sees it.
struct ClaudeDesktopProfileSummary: Equatable {
    let name: String
    /// A profile directory exists on disk.
    let existsOnDisk: Bool
    /// At least one open panel uses the profile.
    let isInUse: Bool
    /// The profile's Claude process is running.
    let isRunning: Bool
}

/// Claude Desktop profiles: one Electron `--user-data-dir` per profile, and
/// one process per profile because of Electron's single-instance lock.
@MainActor
enum ClaudeDesktopProfiles {
    nonisolated static let bundleIdentifier = "com.anthropic.claudefordesktop"

    static let registry = ForeignWindowProfileRegistry { profile in
        ForeignWindowSession(
            identifier: "claude:\(profile)",
            launchConfiguration: ClaudeDesktopProfiles.launchConfiguration(
                profile: profile
            )
        )
    }

    nonisolated static func profilesRootURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(
                "Library/Application Support/cmux",
                isDirectory: true
            )
            .appendingPathComponent(
                "external-apps/claude",
                isDirectory: true
            )
    }

    nonisolated static func profileDirectoryURL(
        profile: String,
        rootURL: URL = profilesRootURL()
    ) -> URL {
        rootURL.appendingPathComponent(profile, isDirectory: true)
    }

    /// Profile names that have a data directory on disk, sorted. Directories
    /// whose names are not normalized profile names are ignored.
    nonisolated static func profilesOnDisk(
        rootURL: URL = profilesRootURL(),
        fileManager: FileManager = .default
    ) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.compactMap { url -> String? in
            let isDirectory = (try? url.resourceValues(
                forKeys: [.isDirectoryKey]
            ))?.isDirectory == true
            guard isDirectory else { return nil }
            let name = url.lastPathComponent
            guard AgentSessionPanel.normalizedDesktopProfile(name) == name else {
                return nil
            }
            return name
        }
        .sorted()
    }

    /// Every profile known on disk or in use, with its live state.
    static func profileSummaries(
        rootURL: URL = profilesRootURL(),
        fileManager: FileManager = .default
    ) -> [ClaudeDesktopProfileSummary] {
        let onDisk = Set(profilesOnDisk(rootURL: rootURL, fileManager: fileManager))
        let inUse = registry.claimedProfiles
        let running = registry.runningProfiles
        return onDisk.union(inUse).union(running).sorted().map { name in
            ClaudeDesktopProfileSummary(
                name: name,
                existsOnDisk: onDisk.contains(name),
                isInUse: inUse.contains(name),
                isRunning: running.contains(name)
            )
        }
    }

    nonisolated static func launchConfiguration(
        profile: String
    ) -> ForeignWindowLaunchConfiguration {
        let fileManager = FileManager.default
        let profileDirectoryURL = profileDirectoryURL(profile: profile)

        let preferredApplicationURL = ProcessInfo.processInfo.environment[
            "CMUX_CLAUDE_DESKTOP_APP_PATH"
        ].flatMap { rawPath -> URL? in
            let trimmed = rawPath.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: trimmed)
        }

        return ForeignWindowLaunchConfiguration(
            bundleIdentifier: bundleIdentifier,
            preferredApplicationURL: preferredApplicationURL,
            fallbackApplicationURLs: [
                URL(fileURLWithPath: "/Applications/Claude.app"),
                fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "Applications/Claude.app",
                        isDirectory: true
                    )
            ],
            arguments: [
                "--user-data-dir=\(profileDirectoryURL.path)"
            ],
            environment: [:],
            directoriesToCreate: [profileDirectoryURL]
        )
    }
}
