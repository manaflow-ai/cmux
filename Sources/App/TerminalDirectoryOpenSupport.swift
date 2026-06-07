import AppKit
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
    case jupyterInline
    case warp
    case windsurf
    case xcode
    case zed

    struct DetectionEnvironment {
        let homeDirectoryPath: String
        let pathEnvironment: String
        let fileExistsAtPath: (String) -> Bool
        let isExecutableFileAtPath: (String) -> Bool
        let applicationPathForName: (String) -> String?

        static let live = DetectionEnvironment(
            homeDirectoryPath: FileManager.default.homeDirectoryForCurrentUser.path,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"] ?? "",
            fileExistsAtPath: { FileManager.default.fileExists(atPath: $0) },
            isExecutableFileAtPath: { FileManager.default.isExecutableFile(atPath: $0) },
            applicationPathForName: { NSWorkspace.shared.fullPath(forApplication: $0) }
        )
    }

    static var commandPaletteShortcutTargets: [Self] {
        Array(allCases)
    }

    static var inlineOpenFolderTargets: [Self] {
        InlineWebAppRegistry.default.profiles.map(\.target)
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
        case .jupyterInline:
            return String(localized: "menu.openInJupyterInline", defaultValue: "Open Current Directory in Jupyter (Inline)")
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
        case .jupyterInline:
            return common + ["jupyter", "notebook", "lab", "inline", "browser", "python"]
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
        if let profile = InlineWebAppRegistry.default.profile(for: self) {
            return profile.isAvailable(in: environment)
        }
        guard let applicationPath = applicationPath(in: environment) else { return false }
        return true
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
        case .jupyterInline:
            return []
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

nonisolated struct InlineWebAppLaunchConfiguration {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let connectionTokenFileURL: URL?
}

enum InlineWebAppExecutable {
    case applicationBundle(bundlePathCandidates: [String], executableRelativePath: String)
    case command(names: [String], fallbackPaths: [String])

    func resolve(in environment: TerminalDirectoryOpenTarget.DetectionEnvironment) -> URL? {
        switch self {
        case .applicationBundle(let bundlePathCandidates, let executableRelativePath):
            for bundlePath in expandedBundlePaths(bundlePathCandidates, homeDirectoryPath: environment.homeDirectoryPath)
                where environment.fileExistsAtPath(bundlePath) {
                let executablePath = URL(fileURLWithPath: bundlePath, isDirectory: true)
                    .appendingPathComponent(executableRelativePath, isDirectory: false)
                    .path
                if environment.isExecutableFileAtPath(executablePath) {
                    return URL(fileURLWithPath: executablePath, isDirectory: false)
                }
            }

            let applicationNames = inlineWebAppUniquePreservingOrder(
                bundlePathCandidates.map {
                    URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                }
            )
            for applicationName in applicationNames {
                guard let bundlePath = environment.applicationPathForName(applicationName),
                      environment.fileExistsAtPath(bundlePath) else {
                    continue
                }
                let executablePath = URL(fileURLWithPath: bundlePath, isDirectory: true)
                    .appendingPathComponent(executableRelativePath, isDirectory: false)
                    .path
                if environment.isExecutableFileAtPath(executablePath) {
                    return URL(fileURLWithPath: executablePath, isDirectory: false)
                }
            }
            return nil
        case .command(let names, let fallbackPaths):
            let pathDirectories = environment.pathEnvironment
                .split(separator: ":", omittingEmptySubsequences: true)
                .map(String.init)
            var candidates = fallbackPaths
            for directory in pathDirectories {
                for name in names {
                    candidates.append(
                        URL(fileURLWithPath: directory, isDirectory: true)
                            .appendingPathComponent(name, isDirectory: false)
                            .path
                    )
                }
            }
            for path in inlineWebAppUniquePreservingOrder(candidates) where environment.isExecutableFileAtPath(path) {
                return URL(fileURLWithPath: path, isDirectory: false)
            }
            return nil
        }
    }

    private func expandedBundlePaths(_ paths: [String], homeDirectoryPath: String) -> [String] {
        let globalPrefix = "/Applications/"
        let userPrefix = "\(homeDirectoryPath)/Applications/"
        var expanded: [String] = []
        for path in paths {
            expanded.append(path)
            if path.hasPrefix(globalPrefix) {
                expanded.append(userPrefix + String(path.dropFirst(globalPrefix.count)))
            }
        }
        return inlineWebAppUniquePreservingOrder(expanded)
    }
}

enum InlineWebAppArgument {
    case literal(String)
    case directoryPath
    case connectionTokenFilePath

    func value(directoryURL: URL, connectionTokenFileURL: URL?) -> String? {
        switch self {
        case .literal(let value):
            return value
        case .directoryPath:
            return directoryURL.path(percentEncoded: false)
        case .connectionTokenFilePath:
            return connectionTokenFileURL?.path
        }
    }
}

enum InlineWebAppServerIdentity {
    case global
    case directory

    func value(for directoryURL: URL) -> String {
        switch self {
        case .global:
            return "global"
        case .directory:
            return directoryURL.standardizedFileURL.path(percentEncoded: false)
        }
    }
}

enum InlineWebAppOpenURLStrategy {
    case queryItem(name: String)
    case direct

    func url(baseURL: URL, directoryURL: URL) -> URL? {
        switch self {
        case .queryItem(let name):
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            var queryItems = components?.queryItems ?? []
            queryItems.removeAll { $0.name == name }
            queryItems.append(URLQueryItem(name: name, value: directoryURL.path(percentEncoded: false)))
            components?.queryItems = queryItems
            return components?.url
        case .direct:
            return baseURL
        }
    }
}

enum InlineWebAppOutputURLExtractor {
    case linePrefix(String)
    case firstLoopbackHTTPURL

    func extract(from output: String) -> URL? {
        switch self {
        case .linePrefix(let prefix):
            for line in output.split(whereSeparator: \.isNewline).reversed() {
                guard let range = line.range(of: prefix) else { continue }
                let rawURL = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawURL.isEmpty, let url = URL(string: rawURL) else { continue }
                return url
            }
            return nil
        case .firstLoopbackHTTPURL:
            guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"']+"#) else { return nil }
            let nsRange = NSRange(output.startIndex..<output.endIndex, in: output)
            for match in regex.matches(in: output, range: nsRange).reversed() {
                guard let range = Range(match.range, in: output) else { continue }
                let rawURL = String(output[range])
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,);]}\n\r\t "))
                guard let url = URL(string: rawURL),
                      let host = url.host?.lowercased(),
                      ["127.0.0.1", "localhost", "::1"].contains(host) else {
                    continue
                }
                return url
            }
            return nil
        }
    }
}

struct InlineWebAppProfile {
    let target: TerminalDirectoryOpenTarget
    let displayName: () -> String
    let openFolderCommandId: String
    let openFolderTitle: () -> String
    let openFolderSubtitle: () -> String
    let openFolderPanelTitle: () -> String
    let openFolderPanelPrompt: () -> String
    let stopServerCommandId: String
    let stopServerTitle: () -> String
    let restartServerCommandId: String
    let restartServerTitle: () -> String
    let keywords: [String]
    let executable: InlineWebAppExecutable
    let arguments: [InlineWebAppArgument]
    let serverIdentity: InlineWebAppServerIdentity
    let openURLStrategy: InlineWebAppOpenURLStrategy
    let outputURLExtractor: InlineWebAppOutputURLExtractor
    let requiresConnectionTokenFile: Bool
    let environmentTransform: ([String: String]) -> [String: String]

    func isAvailable(in environment: TerminalDirectoryOpenTarget.DetectionEnvironment = .live) -> Bool {
        executable.resolve(in: environment) != nil
    }

    func serverIdentityValue(for directoryURL: URL) -> String {
        serverIdentity.value(for: directoryURL)
    }

    func openURL(baseURL: URL, directoryURL: URL) -> URL? {
        openURLStrategy.url(baseURL: baseURL, directoryURL: directoryURL)
    }

    func launchConfiguration(
        directoryURL: URL,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        environment: TerminalDirectoryOpenTarget.DetectionEnvironment = .live
    ) -> InlineWebAppLaunchConfiguration? {
        guard let executableURL = executable.resolve(in: environment) else { return nil }
        let connectionTokenFileURL: URL?
        if requiresConnectionTokenFile {
            guard let tokenFileURL = Self.makeConnectionTokenFile(targetRawValue: target.rawValue) else { return nil }
            connectionTokenFileURL = tokenFileURL
        } else {
            connectionTokenFileURL = nil
        }

        var resolvedArguments: [String] = []
        for argument in arguments {
            guard let value = argument.value(
                directoryURL: directoryURL,
                connectionTokenFileURL: connectionTokenFileURL
            ) else {
                if let connectionTokenFileURL {
                    Self.removeConnectionTokenFile(at: connectionTokenFileURL)
                }
                return nil
            }
            resolvedArguments.append(value)
        }

        return InlineWebAppLaunchConfiguration(
            executableURL: executableURL,
            arguments: resolvedArguments,
            environment: environmentTransform(baseEnvironment),
            connectionTokenFileURL: connectionTokenFileURL
        )
    }

    private static func randomConnectionToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func makeConnectionTokenFile(targetRawValue: String) -> URL? {
        let token = randomConnectionToken()
        let tokenFileName = "cmux-\(targetRawValue)-token-\(UUID().uuidString)"
        let tokenFileURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(tokenFileName, isDirectory: false)
        guard let tokenData = token.data(using: .utf8) else { return nil }

        let fileDescriptor = open(tokenFileURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else { return nil }
        defer { _ = close(fileDescriptor) }

        let wroteAllBytes = tokenData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            return write(fileDescriptor, baseAddress, rawBuffer.count) == rawBuffer.count
        }
        guard wroteAllBytes else {
            removeConnectionTokenFile(at: tokenFileURL)
            return nil
        }

        return tokenFileURL
    }

    static func removeConnectionTokenFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

struct InlineWebAppRegistry {
    static let `default` = InlineWebAppRegistry(profiles: [
        InlineWebAppProfile.vscode,
        InlineWebAppProfile.jupyter,
    ])

    let profiles: [InlineWebAppProfile]

    func profile(for target: TerminalDirectoryOpenTarget) -> InlineWebAppProfile? {
        profiles.first { $0.target == target }
    }
}

extension InlineWebAppProfile {
    static let vscode = InlineWebAppProfile(
        target: .vscodeInline,
        displayName: {
            String(localized: "command.openFolderInVSCodeInline.subtitle", defaultValue: "VS Code Inline")
        },
        openFolderCommandId: "palette.openFolderInVSCodeInline",
        openFolderTitle: {
            String(localized: "command.openFolderInVSCodeInline.title", defaultValue: "Open Folder in VS Code (Inline)...")
        },
        openFolderSubtitle: {
            String(localized: "command.openFolderInVSCodeInline.subtitle", defaultValue: "VS Code Inline")
        },
        openFolderPanelTitle: {
            String(localized: "menu.file.openFolderInVSCodeInline.panelTitle", defaultValue: "Open Folder in VS Code (Inline)")
        },
        openFolderPanelPrompt: {
            String(localized: "menu.file.openFolderInVSCodeInline.panelPrompt", defaultValue: "Open in VS Code")
        },
        stopServerCommandId: "palette.vscodeServeWebStop",
        stopServerTitle: {
            String(localized: "command.vscodeServeWebStop.title", defaultValue: "Stop VS Code Inline Server")
        },
        restartServerCommandId: "palette.vscodeServeWebRestart",
        restartServerTitle: {
            String(localized: "command.vscodeServeWebRestart.title", defaultValue: "Restart VS Code Inline Server")
        },
        keywords: ["open", "folder", "directory", "project", "vs", "code", "inline", "editor", "browser"],
        executable: .applicationBundle(
            bundlePathCandidates: ["/Applications/Visual Studio Code.app", "/Applications/Code.app"],
            executableRelativePath: "Contents/Resources/app/bin/code-tunnel"
        ),
        arguments: [
            .literal("serve-web"),
            .literal("--accept-server-license-terms"),
            .literal("--host"),
            .literal("127.0.0.1"),
            .literal("--port"),
            .literal("0"),
            .literal("--connection-token-file"),
            .connectionTokenFilePath,
        ],
        serverIdentity: .global,
        openURLStrategy: .queryItem(name: "folder"),
        outputURLExtractor: .linePrefix("Web UI available at "),
        requiresConnectionTokenFile: true,
        environmentTransform: { baseEnvironment in
            var environment = baseEnvironment
            environment["ELECTRON_RUN_AS_NODE"] = "1"
            environment.removeValue(forKey: "VSCODE_NODE_OPTIONS")
            environment.removeValue(forKey: "VSCODE_NODE_REPL_EXTERNAL_MODULE")
            if let nodeOptions = environment["NODE_OPTIONS"] {
                environment["VSCODE_NODE_OPTIONS"] = nodeOptions
            }
            if let nodeReplExternalModule = environment["NODE_REPL_EXTERNAL_MODULE"] {
                environment["VSCODE_NODE_REPL_EXTERNAL_MODULE"] = nodeReplExternalModule
            }
            environment.removeValue(forKey: "NODE_OPTIONS")
            environment.removeValue(forKey: "NODE_REPL_EXTERNAL_MODULE")
            return environment
        }
    )

    static let jupyter = InlineWebAppProfile(
        target: .jupyterInline,
        displayName: {
            String(localized: "command.openFolderInJupyterInline.subtitle", defaultValue: "Jupyter Inline")
        },
        openFolderCommandId: "palette.openFolderInJupyterInline",
        openFolderTitle: {
            String(localized: "command.openFolderInJupyterInline.title", defaultValue: "Open Folder in Jupyter (Inline)...")
        },
        openFolderSubtitle: {
            String(localized: "command.openFolderInJupyterInline.subtitle", defaultValue: "Jupyter Inline")
        },
        openFolderPanelTitle: {
            String(localized: "menu.file.openFolderInJupyterInline.panelTitle", defaultValue: "Open Folder in Jupyter (Inline)")
        },
        openFolderPanelPrompt: {
            String(localized: "menu.file.openFolderInJupyterInline.panelPrompt", defaultValue: "Open in Jupyter")
        },
        stopServerCommandId: "palette.jupyterServeWebStop",
        stopServerTitle: {
            String(localized: "command.jupyterServeWebStop.title", defaultValue: "Stop Jupyter Inline Server")
        },
        restartServerCommandId: "palette.jupyterServeWebRestart",
        restartServerTitle: {
            String(localized: "command.jupyterServeWebRestart.title", defaultValue: "Restart Jupyter Inline Server")
        },
        keywords: ["open", "folder", "directory", "project", "jupyter", "notebook", "lab", "inline", "browser", "python"],
        executable: .command(
            names: ["jupyter"],
            fallbackPaths: ["/opt/homebrew/bin/jupyter", "/usr/local/bin/jupyter", "/opt/local/bin/jupyter"]
        ),
        arguments: [
            .literal("lab"),
            .literal("--no-browser"),
            .literal("--ip=127.0.0.1"),
            .literal("--port=0"),
            .literal("--ServerApp.open_browser=False"),
            .literal("--ServerApp.root_dir"),
            .directoryPath,
        ],
        serverIdentity: .directory,
        openURLStrategy: .direct,
        outputURLExtractor: .firstLoopbackHTTPURL,
        requiresConnectionTokenFile: false,
        environmentTransform: { $0 }
    )
}

final class InlineWebAppRuntimeManager {
    static let shared = InlineWebAppRuntimeManager()

    private let lock = NSLock()
    private var controllers: [TerminalDirectoryOpenTarget: InlineWebAppController] = [:]

    func ensureOpenURL(
        for profile: InlineWebAppProfile,
        directoryURL: URL,
        completion: @escaping (URL?) -> Void
    ) {
        controller(for: profile).ensureServerURL(directoryURL: directoryURL) { serverURL in
            guard let serverURL else {
                completion(nil)
                return
            }
            completion(profile.openURL(baseURL: serverURL, directoryURL: directoryURL.standardizedFileURL))
        }
    }

    func stop(profile: InlineWebAppProfile) {
        controller(for: profile).stop()
    }

    func restart(
        profile: InlineWebAppProfile,
        directoryURL: URL,
        completion: @escaping (URL?) -> Void
    ) {
        controller(for: profile).restart(directoryURL: directoryURL, completion: completion)
    }

    private func controller(for profile: InlineWebAppProfile) -> InlineWebAppController {
        lock.lock()
        defer { lock.unlock() }
        if let controller = controllers[profile.target] {
            return controller
        }
        let controller = InlineWebAppController(profile: profile)
        controllers[profile.target] = controller
        return controller
    }
}

final class InlineWebAppController {
    private static let startupTimeoutSeconds: TimeInterval = 60

    private let profile: InlineWebAppProfile
    private let queue: DispatchQueue
    private let launchQueue: DispatchQueue
    private let launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)?
    private var serverProcess: Process?
    private var launchingProcess: Process?
    private var connectionTokenFilesByProcessID: [ObjectIdentifier: URL] = [:]
    private var serverURL: URL?
    private var serverIdentityValue: String?
    private var pendingCompletions: [(generation: UInt64, completion: (URL?) -> Void)] = []
    private var isLaunching = false
    private var activeLaunchGeneration: UInt64?
    private var lifecycleGeneration: UInt64 = 0
#if DEBUG
    private var testingTrackedProcesses: [Process] = []
#endif

    init(
        profile: InlineWebAppProfile,
        launchProcessOverride: ((URL, UInt64) -> (process: Process, url: URL)?)? = nil
    ) {
        self.profile = profile
        self.queue = DispatchQueue(label: "cmux.inlineWebApp.\(profile.target.rawValue)")
        self.launchQueue = DispatchQueue(label: "cmux.inlineWebApp.\(profile.target.rawValue).launch")
        self.launchProcessOverride = launchProcessOverride
    }

#if DEBUG
    static func makeForTesting(
        profile: InlineWebAppProfile,
        launchProcessOverride: @escaping (URL, UInt64) -> (process: Process, url: URL)?
    ) -> InlineWebAppController {
        InlineWebAppController(profile: profile, launchProcessOverride: launchProcessOverride)
    }

    func trackConnectionTokenFileForTesting(
        _ connectionTokenFileURL: URL,
        setAsLaunchingProcess: Bool = false,
        setAsServeWebProcess: Bool = false
    ) {
        let process = Process()
        queue.sync {
            if setAsLaunchingProcess {
                self.launchingProcess = process
            }
            if setAsServeWebProcess {
                self.serverProcess = process
            }
            if !setAsLaunchingProcess && !setAsServeWebProcess {
                self.testingTrackedProcesses.append(process)
            }
            self.connectionTokenFilesByProcessID[ObjectIdentifier(process)] = connectionTokenFileURL
        }
    }
#endif

    func ensureServerURL(directoryURL: URL, completion: @escaping (URL?) -> Void) {
        let normalizedDirectoryURL = directoryURL.standardizedFileURL
        let requestedIdentity = profile.serverIdentityValue(for: normalizedDirectoryURL)
        queue.async {
            if let process = self.serverProcess,
               process.isRunning,
               let url = self.serverURL,
               self.serverIdentityValue == requestedIdentity {
                DispatchQueue.main.async { completion(url) }
                return
            }

            if self.serverIdentityValue != nil,
               self.serverIdentityValue != requestedIdentity {
                Self.finishStop(self.stopLocked(completePendingWithNil: true))
            }

            let completionGeneration = self.lifecycleGeneration
            self.pendingCompletions.append((generation: completionGeneration, completion: completion))
            guard !self.isLaunching else { return }

            self.isLaunching = true
            self.serverIdentityValue = requestedIdentity
            let launchGeneration = completionGeneration
            self.activeLaunchGeneration = launchGeneration

            self.launchQueue.async {
                let shouldLaunch = self.queue.sync { self.lifecycleGeneration == launchGeneration }
                guard shouldLaunch else {
                    self.queue.async {
                        guard self.activeLaunchGeneration == launchGeneration else { return }
                        self.isLaunching = false
                        self.activeLaunchGeneration = nil
                    }
                    return
                }

                let launchResult = self.launchServerProcess(
                    directoryURL: normalizedDirectoryURL,
                    expectedGeneration: launchGeneration
                )
                self.queue.async {
                    guard self.activeLaunchGeneration == launchGeneration else {
                        if let process = launchResult?.process, process.isRunning {
                            process.terminate()
                        }
                        return
                    }
                    self.isLaunching = false
                    self.activeLaunchGeneration = nil

                    guard self.lifecycleGeneration == launchGeneration else {
                        if let process = launchResult?.process, process.isRunning {
                            process.terminate()
                        }
                        return
                    }

                    if let launchResult {
                        self.launchingProcess = nil
                        self.serverProcess = launchResult.process
                        self.serverURL = launchResult.url
                    } else {
                        self.launchingProcess = nil
                        self.serverProcess = nil
                        self.serverURL = nil
                        self.serverIdentityValue = nil
                    }

                    var completions: [(URL?) -> Void] = []
                    var remaining: [(generation: UInt64, completion: (URL?) -> Void)] = []
                    for pending in self.pendingCompletions {
                        if pending.generation == launchGeneration {
                            completions.append(pending.completion)
                        } else {
                            remaining.append(pending)
                        }
                    }
                    self.pendingCompletions = remaining
                    let resolvedURL = self.serverURL
                    DispatchQueue.main.async {
                        completions.forEach { $0(resolvedURL) }
                    }
                }
            }
        }
    }

    func stop() {
        Self.finishStop(queue.sync { self.stopLocked(completePendingWithNil: true) })
    }

    func restart(directoryURL: URL, completion: @escaping (URL?) -> Void) {
        stop()
        ensureServerURL(directoryURL: directoryURL, completion: completion)
    }

    private func stopLocked(
        completePendingWithNil: Bool
    ) -> (processes: [Process], tokenFileURLs: [URL], completions: [(URL?) -> Void]) {
        lifecycleGeneration &+= 1
        isLaunching = false
        activeLaunchGeneration = nil
        let processes = [serverProcess, launchingProcess].compactMap { $0 }
        serverProcess = nil
        launchingProcess = nil
#if DEBUG
        testingTrackedProcesses.removeAll()
#endif
        var tokenFileURLs = processes.compactMap {
            connectionTokenFilesByProcessID.removeValue(forKey: ObjectIdentifier($0))
        }
        tokenFileURLs.append(contentsOf: connectionTokenFilesByProcessID.values)
        connectionTokenFilesByProcessID.removeAll()
        serverURL = nil
        serverIdentityValue = nil
        let completions = completePendingWithNil ? pendingCompletions.map(\.completion) : []
        if completePendingWithNil {
            pendingCompletions.removeAll()
        }
        return (processes, tokenFileURLs, completions)
    }

    private static func finishStop(
        _ stopped: (processes: [Process], tokenFileURLs: [URL], completions: [(URL?) -> Void])
    ) {
        for tokenFileURL in stopped.tokenFileURLs {
            InlineWebAppProfile.removeConnectionTokenFile(at: tokenFileURL)
        }
        for process in stopped.processes where process.isRunning {
            process.terminate()
        }
        if !stopped.completions.isEmpty {
            DispatchQueue.main.async {
                stopped.completions.forEach { $0(nil) }
            }
        }
    }

    private func launchServerProcess(
        directoryURL: URL,
        expectedGeneration: UInt64
    ) -> (process: Process, url: URL)? {
        if let launchProcessOverride {
            return launchProcessOverride(directoryURL, expectedGeneration)
        }

        guard let launchConfiguration = profile.launchConfiguration(directoryURL: directoryURL) else {
            return nil
        }

        let process = Process()
        process.executableURL = launchConfiguration.executableURL
        process.arguments = launchConfiguration.arguments
        process.environment = launchConfiguration.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = InlineWebAppOutputCollector(extractor: profile.outputURLExtractor)
        let outputReader: (FileHandle) -> Void = { fileHandle in
            switch ProcessPipeReader.readAvailableDataOrEndOfFile(from: fileHandle) {
            case .data(let data):
                collector.append(data)
            case .wouldBlock:
                return
            case .endOfFile:
                fileHandle.readabilityHandler = nil
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = outputReader
        stderrPipe.fileHandleForReading.readabilityHandler = outputReader

        process.terminationHandler = { [weak self] terminatedProcess in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            Self.drainAvailableOutput(from: stdoutPipe.fileHandleForReading, collector: collector)
            Self.drainAvailableOutput(from: stderrPipe.fileHandleForReading, collector: collector)
            collector.markProcessExited()
            self?.queue.async {
                guard let self else { return }
                if self.launchingProcess === terminatedProcess {
                    self.launchingProcess = nil
                }
                if self.serverProcess === terminatedProcess {
                    self.serverProcess = nil
                    self.serverURL = nil
                    self.serverIdentityValue = nil
                }
                if let tokenFileURL = self.connectionTokenFilesByProcessID.removeValue(
                    forKey: ObjectIdentifier(terminatedProcess)
                ) {
                    InlineWebAppProfile.removeConnectionTokenFile(at: tokenFileURL)
                }
            }
        }

        let didStart: Bool = queue.sync {
            guard lifecycleGeneration == expectedGeneration,
                  activeLaunchGeneration == expectedGeneration else {
                return false
            }
            launchingProcess = process
            if let connectionTokenFileURL = launchConfiguration.connectionTokenFileURL {
                connectionTokenFilesByProcessID[ObjectIdentifier(process)] = connectionTokenFileURL
            }
            do {
                try process.run()
                return true
            } catch {
                launchingProcess = nil
                if let tokenFileURL = connectionTokenFilesByProcessID.removeValue(forKey: ObjectIdentifier(process)) {
                    InlineWebAppProfile.removeConnectionTokenFile(at: tokenFileURL)
                }
                return false
            }
        }
        guard didStart else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if let connectionTokenFileURL = launchConfiguration.connectionTokenFileURL {
                InlineWebAppProfile.removeConnectionTokenFile(at: connectionTokenFileURL)
            }
            return nil
        }

        guard collector.waitForURL(timeoutSeconds: Self.startupTimeoutSeconds),
              let serverURL = collector.webUIURL else {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            return nil
        }

        return (process, serverURL)
    }

    private static func drainAvailableOutput(from fileHandle: FileHandle, collector: InlineWebAppOutputCollector) {
        while true {
            switch ProcessPipeReader.readAvailableDataOrEndOfFile(from: fileHandle) {
            case .data(let data):
                collector.append(data)
            case .wouldBlock, .endOfFile:
                return
            }
        }
    }
}

final class InlineWebAppOutputCollector {
    private let extractor: InlineWebAppOutputURLExtractor
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var outputBuffer = ""
    private var resolvedURL: URL?
    private var didSignal = false

    var webUIURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return resolvedURL
    }

    init(extractor: InlineWebAppOutputURLExtractor) {
        self.extractor = extractor
    }

    func append(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard resolvedURL == nil else { return }
        outputBuffer.append(text)
        while let newlineIndex = outputBuffer.firstIndex(where: \.isNewline) {
            let line = String(outputBuffer[..<newlineIndex])
            outputBuffer.removeSubrange(...newlineIndex)
            guard let parsedURL = extractor.extract(from: line) else { continue }
            resolvedURL = parsedURL
            outputBuffer.removeAll(keepingCapacity: false)
            if !didSignal {
                didSignal = true
                semaphore.signal()
            }
            return
        }
    }

    func markProcessExited() {
        lock.lock()
        defer { lock.unlock() }
        if resolvedURL == nil, !outputBuffer.isEmpty,
           let parsedURL = extractor.extract(from: outputBuffer) {
            resolvedURL = parsedURL
            outputBuffer.removeAll(keepingCapacity: false)
        }
        guard !didSignal else { return }
        didSignal = true
        semaphore.signal()
    }

    func waitForURL(timeoutSeconds: TimeInterval) -> Bool {
        if webUIURL != nil { return true }
        _ = semaphore.wait(timeout: .now() + timeoutSeconds)
        return webUIURL != nil
    }
}

private func inlineWebAppUniquePreservingOrder(_ paths: [String]) -> [String] {
    var seen: Set<String> = []
    var deduped: [String] = []
    for path in paths where seen.insert(path).inserted {
        deduped.append(path)
    }
    return deduped
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
