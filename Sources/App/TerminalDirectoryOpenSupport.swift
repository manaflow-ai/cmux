import CmuxFoundation
import CmuxCore
import AppKit
import CmuxCommandPalette
import Darwin
import Foundation

enum FinderServicePathResolver {
    private static func canonicalDirectoryPath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        var canonical = path
        while canonical.count > 1 && canonical.hasSuffix("/") {
            canonical.removeLast()
        }
        return canonical
    }

    private static func normalizedComparisonURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isSameOrDescendant(_ url: URL, of rootURL: URL) -> Bool {
        let urlPathComponents = normalizedComparisonURL(url).pathComponents
        let rootPathComponents = normalizedComparisonURL(rootURL).pathComponents
        guard urlPathComponents.count >= rootPathComponents.count else { return false }
        return Array(urlPathComponents.prefix(rootPathComponents.count)) == rootPathComponents
    }

    private static func resolvedDirectoryURL(from url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if standardized.hasDirectoryPath {
            return standardized
        }
        if let resourceValues = try? standardized.resourceValues(forKeys: [.isDirectoryKey]),
           resourceValues.isDirectory == true {
            return standardized
        }
        return standardized.deletingLastPathComponent()
    }

    static func orderedUniqueDirectories(
        from pathURLs: [URL],
        excludingDescendantsOf excludedRootURLs: [URL] = []
    ) -> [String] {
        var seen: Set<String> = []
        var directories: [String] = []

        for url in pathURLs {
            let directoryURL = resolvedDirectoryURL(from: url)
            guard !excludedRootURLs.contains(where: { isSameOrDescendant(directoryURL, of: $0) }) else {
                continue
            }
            let path = canonicalDirectoryPath(directoryURL.path(percentEncoded: false))
            let dedupePath = canonicalDirectoryPath(
                normalizedComparisonURL(directoryURL).path(percentEncoded: false)
            )
            guard !path.isEmpty, !dedupePath.isEmpty else { continue }
            if seen.insert(dedupePath).inserted {
                directories.append(path)
            }
        }

        return directories
    }
}

enum TerminalDirectoryOpenTarget: String, CaseIterable {
    case androidStudio
    case antigravity
    case cursor
    case devin
    case finder
    case ghostty
    case intellij
    case iterm2
    case terminal
    case tower
    case vscode
    case vscodeInline
    case warp
    case windsurf
    case xcode
    case zed

    struct DetectionEnvironment {
        let homeDirectoryPath: String
        let fileExistsAtPath: (String) -> Bool
        let isExecutableFileAtPath: (String) -> Bool
        let applicationPathForName: (String) -> String?

        static let live = DetectionEnvironment(
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path,
            fileExistsAtPath: { FileManager.default.fileExists(atPath: $0) },
            isExecutableFileAtPath: { FileManager.default.isExecutableFile(atPath: $0) },
            applicationPathForName: { NSWorkspace.shared.fullPath(forApplication: $0) }
        )
    }

    static var commandPaletteShortcutTargets: [Self] {
        Array(allCases)
    }

    static func availableTargets(in environment: DetectionEnvironment = .live) -> Set<Self> {
        Set(commandPaletteShortcutTargets.filter { $0.isAvailable(in: environment) })
    }

    var commandPaletteCommandId: String {
        "palette.terminalOpenDirectory.\(rawValue)"
    }

    var commandPaletteTitle: String {
        switch self {
        case .androidStudio:
            return String(localized: "menu.openInAndroidStudio", defaultValue: "Open Current Directory in Android Studio")
        case .antigravity:
            return String(localized: "menu.openInAntigravity", defaultValue: "Open Current Directory in Antigravity")
        case .cursor:
            return String(localized: "menu.openInCursor", defaultValue: "Open Current Directory in Cursor")
        case .devin:
            return String(localized: "menu.openInDevin", defaultValue: "Open Current Directory in Devin")
        case .finder:
            return String(localized: "menu.openInFinder", defaultValue: "Open Current Directory in Finder")
        case .ghostty:
            return String(localized: "menu.openInGhostty", defaultValue: "Open Current Directory in Ghostty")
        case .intellij:
            return String(localized: "menu.openInIntelliJ", defaultValue: "Open Current Directory in IntelliJ IDEA")
        case .iterm2:
            return String(localized: "menu.openInITerm2", defaultValue: "Open Current Directory in iTerm2")
        case .terminal:
            return String(localized: "menu.openInTerminal", defaultValue: "Open Current Directory in Terminal")
        case .tower:
            return String(localized: "menu.openInTower", defaultValue: "Open Current Directory in Tower")
        case .vscode:
            return String(localized: "menu.openInVSCodeDesktop", defaultValue: "Open Current Directory in VS Code")
        case .vscodeInline:
            return String(localized: "menu.openInVSCode", defaultValue: "Open Current Directory in VS Code (Inline)")
        case .warp:
            return String(localized: "menu.openInWarp", defaultValue: "Open Current Directory in Warp")
        case .windsurf:
            return String(localized: "menu.openInWindsurf", defaultValue: "Open Current Directory in Windsurf")
        case .xcode:
            return String(localized: "menu.openInXcode", defaultValue: "Open Current Directory in Xcode")
        case .zed:
            return String(localized: "menu.openInZed", defaultValue: "Open Current Directory in Zed")
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
        case .devin:
            return common + ["devin", "cognition"]
        case .finder:
            return common + ["finder", "file", "manager", "reveal"]
        case .ghostty:
            return common + ["ghostty", "terminal", "shell"]
        case .intellij:
            return common + ["intellij", "idea", "jetbrains"]
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

    func isAvailable(in environment: DetectionEnvironment = .live) -> Bool {
        guard let applicationPath = applicationPath(in: environment) else { return false }
        guard self == .vscodeInline else { return true }
        // Keep menu/palette availability cheap. Cached code-server discovery does
        // disk I/O and belongs to the actual launch path on the launch queue.
        let codeTunnelURL = URL(fileURLWithPath: applicationPath, isDirectory: true)
            .appendingPathComponent("Contents/Resources/app/bin/code-tunnel", isDirectory: false)
        return environment.isExecutableFileAtPath(codeTunnelURL.path)
    }

    func applicationURL(in environment: DetectionEnvironment = .live) -> URL? {
        guard let path = applicationPath(in: environment) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func applicationPath(in environment: DetectionEnvironment) -> String? {
        for path in expandedCandidatePaths(in: environment) where environment.fileExistsAtPath(path) {
            return path
        }

        // Fall back to LaunchServices so apps outside the standard bundle paths
        // still appear in the command palette.
        for applicationName in applicationSearchNames {
            guard let resolvedPath = environment.applicationPathForName(applicationName),
                  environment.fileExistsAtPath(resolvedPath) else {
                continue
            }
            return resolvedPath
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

    private var applicationSearchNames: [String] {
        uniquePreservingOrder(
            applicationBundlePathCandidates.map {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
            }
        )
    }

    private var applicationBundlePathCandidates: [String] {
        switch self {
        case .androidStudio:
            return ["/Applications/Android Studio.app"]
        case .antigravity:
            return ["/Applications/Antigravity.app"]
        case .cursor:
            return [
                "/Applications/Cursor.app",
                "/Applications/Cursor Preview.app",
                "/Applications/Cursor Nightly.app",
            ]
        case .devin:
            return ["/Applications/Devin.app"]
        case .finder:
            return ["/System/Library/CoreServices/Finder.app"]
        case .ghostty:
            return ["/Applications/Ghostty.app"]
        case .intellij:
            return ["/Applications/IntelliJ IDEA.app"]
        case .iterm2:
            return [
                "/Applications/iTerm.app",
                "/Applications/iTerm2.app",
            ]
        case .terminal:
            return ["/System/Applications/Utilities/Terminal.app"]
        case .tower:
            return ["/Applications/Tower.app"]
        case .vscode:
            return [
                "/Applications/Visual Studio Code.app",
                "/Applications/Code.app",
            ]
        case .vscodeInline:
            return [
                "/Applications/Visual Studio Code.app",
                "/Applications/Code.app",
            ]
        case .warp:
            return ["/Applications/Warp.app"]
        case .windsurf:
            return ["/Applications/Windsurf.app"]
        case .xcode:
            return ["/Applications/Xcode.app"]
        case .zed:
            return [
                "/Applications/Zed.app",
                "/Applications/Zed Preview.app",
                "/Applications/Zed Nightly.app",
            ]
        }
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

enum WorkspaceShortcutMapper {
    /// Maps numbered workspace shortcuts to a zero-based workspace index.
    /// 1...8 target fixed indices; 9 always targets the last workspace.
    static func workspaceIndex(forDigit digit: Int, workspaceCount: Int) -> Int? {
        guard workspaceCount > 0 else { return nil }
        guard (1...9).contains(digit) else { return nil }

        if digit == 9 {
            return workspaceCount - 1
        }

        let index = digit - 1
        return index < workspaceCount ? index : nil
    }

    /// Returns the primary digit badge to display for a workspace row.
    /// Picks the lowest digit that maps to that row index.
    static func digitForWorkspace(at index: Int, workspaceCount: Int) -> Int? {
        guard index >= 0 && index < workspaceCount else { return nil }
        for digit in 1...9 {
            if workspaceIndex(forDigit: digit, workspaceCount: workspaceCount) == index {
                return digit
            }
        }
        return nil
    }
}

extension CommandPaletteContextKeys {
    /// Typed app-side overload over the package's raw-value key builder, so
    /// palette context keys keep the exact `terminal.openTarget.<raw>.available`
    /// format without the package importing the terminal domain.
    static func terminalOpenTargetAvailable(_ target: TerminalDirectoryOpenTarget) -> CommandPaletteContextKeys {
        terminalOpenTargetAvailable(rawValue: target.rawValue)
    }
}
