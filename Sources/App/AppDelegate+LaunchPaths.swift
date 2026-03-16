//
//  AppDelegate+LaunchPaths.swift
//  cmux
//
//  Created by Gale Williams on 3/16/26.
//

import Foundation

// MARK: - FinderServicePathResolver

enum FinderServicePathResolver {
    static func orderedUniqueDirectories(from pathURLs: [URL]) -> [String] {
        var seen: Set<String> = []
        var directories: [String] = []

        for url in pathURLs {
            let standardized = url.standardizedFileURL
            let directoryURL = standardized.hasDirectoryPath ? standardized : standardized.deletingLastPathComponent()
            let path = canonicalDirectoryPath(directoryURL.path(percentEncoded: false))
            guard !path.isEmpty else { continue }
            if seen.insert(path).inserted {
                directories.append(path)
            }
        }

        return directories
    }

    private static func canonicalDirectoryPath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var canonical = path
        while canonical.count > 1, canonical.hasSuffix("/") {
            canonical.removeLast()
        }
        return canonical
    }
}

// MARK: - TerminalDirectoryOpenTarget

enum TerminalDirectoryOpenTarget: String, CaseIterable {
    case androidStudio
    case antigravity
    case cursor
    case finder
    case ghostty
    case iterm2
    case terminal
    case tower
    case vscode
    case vscodeInline
    case warp
    case windsurf
    case xcode
    case zed

    // MARK: Nested Types

    struct DetectionEnvironment {
        // MARK: Static Properties

        static let live = DetectionEnvironment(
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path,
            fileExistsAtPath: { FileManager.default.fileExists(atPath: $0) },
            isExecutableFileAtPath: { FileManager.default.isExecutableFile(atPath: $0) }
        )

        // MARK: Properties

        let homeDirectoryPath: String
        let fileExistsAtPath: (String) -> Bool
        let isExecutableFileAtPath: (String) -> Bool
    }

    // MARK: Static Properties

    static let cachedLiveAvailableTargets: Set<Self> = availableTargets(in: .live)

    // MARK: Static Computed Properties

    static var commandPaletteShortcutTargets: [Self] {
        Array(allCases)
    }

    // MARK: Computed Properties

    var commandPaletteCommandId: String {
        "palette.terminalOpenDirectory.\(rawValue)"
    }

    var commandPaletteTitle: String {
        switch self {
            case .androidStudio:
                String(localized: "menu.openInAndroidStudio", defaultValue: "Open Current Directory in Android Studio")
            case .antigravity:
                String(localized: "menu.openInAntigravity", defaultValue: "Open Current Directory in Antigravity")
            case .cursor:
                String(localized: "menu.openInCursor", defaultValue: "Open Current Directory in Cursor")
            case .finder:
                String(localized: "menu.openInFinder", defaultValue: "Open Current Directory in Finder")
            case .ghostty:
                String(localized: "menu.openInGhostty", defaultValue: "Open Current Directory in Ghostty")
            case .iterm2:
                String(localized: "menu.openInITerm2", defaultValue: "Open Current Directory in iTerm2")
            case .terminal:
                String(localized: "menu.openInTerminal", defaultValue: "Open Current Directory in Terminal")
            case .tower:
                String(localized: "menu.openInTower", defaultValue: "Open Current Directory in Tower")
            case .vscode:
                String(localized: "menu.openInVSCodeDesktop", defaultValue: "Open Current Directory in VS Code")
            case .vscodeInline:
                String(localized: "menu.openInVSCode", defaultValue: "Open Current Directory in VS Code (Inline)")
            case .warp:
                String(localized: "menu.openInWarp", defaultValue: "Open Current Directory in Warp")
            case .windsurf:
                String(localized: "menu.openInWindsurf", defaultValue: "Open Current Directory in Windsurf")
            case .xcode:
                String(localized: "menu.openInXcode", defaultValue: "Open Current Directory in Xcode")
            case .zed:
                String(localized: "menu.openInZed", defaultValue: "Open Current Directory in Zed")
        }
    }

    var commandPaletteKeywords: [String] {
        let common = ["terminal", "directory", "open", "ide"]
        switch self {
            case .androidStudio:
                return common + ["android", "studio"]
            case .antigravity:
                return common + ["antigravity"]
            case .cursor:
                return common + ["cursor"]
            case .finder:
                return common + ["finder", "file", "manager", "reveal"]
            case .ghostty:
                return common + ["ghostty", "terminal", "shell"]
            case .iterm2:
                return common + ["iterm", "iterm2", "terminal", "shell"]
            case .terminal:
                return common + ["terminal", "shell"]
            case .tower:
                return common + ["tower", "git", "client"]
            case .vscode:
                return common + ["vs", "code", "visual", "studio", "desktop", "app"]
            case .vscodeInline:
                return common + ["vs", "code", "visual", "studio", "inline", "browser", "serve-web"]
            case .warp:
                return common + ["warp", "terminal", "shell"]
            case .windsurf:
                return common + ["windsurf"]
            case .xcode:
                return common + ["xcode", "apple"]
            case .zed:
                return common + ["zed"]
        }
    }

    private var applicationBundlePathCandidates: [String] {
        switch self {
            case .androidStudio:
                ["/Applications/Android Studio.app"]

            case .antigravity:
                ["/Applications/Antigravity.app"]

            case .cursor:
                [
                    "/Applications/Cursor.app",
                    "/Applications/Cursor Preview.app",
                    "/Applications/Cursor Nightly.app",
                ]

            case .finder:
                ["/System/Library/CoreServices/Finder.app"]

            case .ghostty:
                ["/Applications/Ghostty.app"]

            case .iterm2:
                [
                    "/Applications/iTerm.app",
                    "/Applications/iTerm2.app",
                ]

            case .terminal:
                ["/System/Applications/Utilities/Terminal.app"]

            case .tower:
                ["/Applications/Tower.app"]

            case .vscode:
                [
                    "/Applications/Visual Studio Code.app",
                    "/Applications/Code.app",
                ]

            case .vscodeInline:
                [
                    "/Applications/Visual Studio Code.app",
                    "/Applications/Code.app",
                ]

            case .warp:
                ["/Applications/Warp.app"]

            case .windsurf:
                ["/Applications/Windsurf.app"]

            case .xcode:
                ["/Applications/Xcode.app"]

            case .zed:
                [
                    "/Applications/Zed.app",
                    "/Applications/Zed Preview.app",
                    "/Applications/Zed Nightly.app",
                ]
        }
    }

    // MARK: Static Functions

    static func availableTargets(in environment: DetectionEnvironment = .live) -> Set<Self> {
        Set(commandPaletteShortcutTargets.filter { $0.isAvailable(in: environment) })
    }

    // MARK: Functions

    func isAvailable(in environment: DetectionEnvironment = .live) -> Bool {
        guard let applicationPath = applicationPath(in: environment) else { return false }
        guard self == .vscodeInline else { return true }
        return VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: URL(fileURLWithPath: applicationPath, isDirectory: true),
            isExecutableAtPath: environment.isExecutableFileAtPath
        ) != nil
    }

    func applicationURL(in environment: DetectionEnvironment = .live) -> URL? {
        guard let path = applicationPath(in: environment) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func applicationPath(in environment: DetectionEnvironment) -> String? {
        for path in expandedCandidatePaths(in: environment) where environment.fileExistsAtPath(path) {
            return path
        }
        return nil
    }

    private func expandedCandidatePaths(in environment: DetectionEnvironment) -> [String] {
        let globalPrefix = "/Applications/"
        let userPrefix = "\(environment.homeDirectoryPath)/Applications/"
        var expanded: [String] = []

        for candidate in applicationBundlePathCandidates {
            expanded.append(candidate)
            if candidate.hasPrefix(globalPrefix) {
                let suffix = String(candidate.dropFirst(globalPrefix.count))
                expanded.append(userPrefix + suffix)
            }
        }

        return uniquePreservingOrder(expanded)
    }

    private func uniquePreservingOrder(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var deduped: [String] = []
        for path in paths where seen.insert(path).inserted {
            deduped.append(path)
        }
        return deduped
    }
}

// MARK: - VSCodeServeWebURLBuilder

enum VSCodeServeWebURLBuilder {
    static func extractWebUIURL(from output: String) -> URL? {
        let prefix = "Web UI available at "
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let range = line.range(of: prefix) else { continue }
            let rawURL = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawURL.isEmpty, let url = URL(string: rawURL) else { continue }
            return url
        }
        return nil
    }

    static func openFolderURL(baseWebUIURL: URL, directoryPath: String) -> URL? {
        var components = URLComponents(url: baseWebUIURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.removeAll { $0.name == "folder" }
        queryItems.append(URLQueryItem(name: "folder", value: directoryPath))
        components?.queryItems = queryItems
        return components?.url
    }
}
